#!/usr/bin/env bash
#
# moodle-assign2page.sh
# --------------------------------------------------------------------------
# Converts Moodle "Assignment" (mod_assign) activities into "Textseite" /
# Page (mod_page) activities: same name, same description content, manual
# completion tracking. Interactive, self-discovering, backs up the DB
# before touching anything.
#
# USAGE
#   ./moodle-assign2page.sh              interactive conversion run
#   ./moodle-assign2page.sh --restore    restore the DB from a dump in cwd
#   ./moodle-assign2page.sh --help
#
# Only dependency assumptions: this is a plain (non-Docker) Debian server
# with PHP CLI (PHP: Command-Line Interface) and either the mysql/mysqldump
# or psql/pg_dump client tools installed (whichever matches your Moodle DB
# (Database)).
#
# Safety: takes a full DB dump before any write. On failure it offers to
# restore that same dump immediately. Dumps are left in the working
# directory for later use with --restore.
# --------------------------------------------------------------------------

set -uo pipefail

CACHE_FILE="$HOME/.moodle_assign2page.conf"
TMP_PHP=""

# ---------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""; C_NC=""
fi
log_info() { echo "${C_BOLD}[..]${C_NC} $*"; }
log_ok()   { echo "${C_GREEN}[ok]${C_NC} $*"; }
log_warn() { echo "${C_YELLOW}[!!]${C_NC} $*"; }
log_err()  { echo "${C_RED}[XX]${C_NC} $*" >&2; }
confirm() {
  local prompt="$1" default="${2:-N}" ans
  if [ "$default" = "Y" ]; then prompt="$prompt [Y/n]: "; else prompt="$prompt [y/N]: "; fi
  read -rp "$prompt" ans || ans=""
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}
cleanup() { [ -n "$TMP_PHP" ] && rm -f "$TMP_PHP"; }
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  ./moodle-assign2page.sh              Interactive: convert assignments to Textseite
  ./moodle-assign2page.sh --restore    Restore the DB from a dump file in this directory
  ./moodle-assign2page.sh --help       Show this help

Env overrides (optional, skip auto-discovery):
  MOODLE_CONFIG=/path/to/config.php
EOF
}

# ---------------------------------------------------------------------
# discover Moodle install (config.php) - cached after first successful run
# ---------------------------------------------------------------------
is_real_config() {
  # Only the real site config.php sets both of these - theme, cache and
  # plugin config.php files never do (even though many of them also carry
  # the generic MOODLE_INTERNAL include guard, which is why that alone
  # isn't a reliable filter).
  grep -q '\$CFG->dbtype' "$1" 2>/dev/null && grep -q '\$CFG->wwwroot' "$1" 2>/dev/null
}

discover_config() {
  if [ -n "${MOODLE_CONFIG:-}" ] && [ -f "$MOODLE_CONFIG" ]; then
    CONFIG_FILE="$MOODLE_CONFIG"
    log_ok "Using MOODLE_CONFIG=$CONFIG_FILE"
    return
  fi

  if [ -f "$CACHE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CACHE_FILE"
    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ] && is_real_config "$CONFIG_FILE"; then
      if confirm "Use previously found Moodle install at $CONFIG_FILE?" Y; then
        return
      fi
    fi
  fi

  log_info "Looking for your Moodle install..."
  declare -A seen=()
  local candidates=() real

  # Quick pass: classic docroot AND the newer Moodle 4.5+ layout where the
  # served code lives under a public/ subdirectory, one level of
  # subdirectory deep too (e.g. /var/www/html/moodle/public/config.php).
  local bases=(/var/www/html /var/www/moodle /var/www /srv/moodle /opt/moodle /usr/share/moodle)
  for base in "${bases[@]}"; do
    for p in "$base/config.php" "$base/public/config.php" "$base"/*/config.php "$base"/*/public/config.php; do
      [ -f "$p" ] || continue
      is_real_config "$p" || continue
      real=$(readlink -f "$p")
      [ -n "${seen[$real]:-}" ] && continue
      seen[$real]=1
      candidates+=("$p")
    done
  done

  if [ ${#candidates[@]} -eq 0 ]; then
    log_info "Not in common locations, doing a broader filesystem search (this can take a moment)..."
    while IFS= read -r f; do
      is_real_config "$f" || continue
      real=$(readlink -f "$f")
      [ -n "${seen[$real]:-}" ] && continue
      seen[$real]=1
      candidates+=("$f")
    done < <(find / \( -path /proc -o -path /sys -o -path /dev -o -path /home \) -prune -o \
              -maxdepth 9 -iname "config.php" -print 2>/dev/null)
  fi

  if [ ${#candidates[@]} -eq 1 ]; then
    CONFIG_FILE="${candidates[0]}"
    log_ok "Found Moodle at: $CONFIG_FILE"
  elif [ ${#candidates[@]} -gt 1 ]; then
    echo "Found multiple Moodle installs:"
    local i=1
    for c in "${candidates[@]}"; do echo "  $i) $c"; i=$((i+1)); done
    local sel
    read -rp "Which one? [1-${#candidates[@]}]: " sel
    CONFIG_FILE="${candidates[$((sel-1))]}"
  else
    log_warn "Could not auto-discover config.php."
    read -rp "Enter the full path to your Moodle config.php: " CONFIG_FILE
  fi

  if [ ! -f "$CONFIG_FILE" ]; then
    log_err "File not found: $CONFIG_FILE"
    exit 1
  fi
  if [ ! -r "$CONFIG_FILE" ]; then
    log_err "Cannot read $CONFIG_FILE (permission denied). Try running this script with sudo."
    exit 1
  fi

  echo "CONFIG_FILE=\"$CONFIG_FILE\"" > "$CACHE_FILE"
}

# ---------------------------------------------------------------------
# parse DB + paths out of config.php
# ---------------------------------------------------------------------
cfg_val() {
  local key="$1"
  sed -n -E "s/^[[:space:]]*\\\$CFG->${key}[[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p" "$CONFIG_FILE" | head -n1
}
dboption_val() {
  local key="$1"
  sed -n -E "s/^[[:space:]]*'${key}'[[:space:]]*=>[[:space:]]*'?([^',]*)'?,?.*/\\1/p" "$CONFIG_FILE" | head -n1
}

parse_config() {
  DBTYPE=$(cfg_val dbtype)
  DBHOST=$(cfg_val dbhost)
  DBNAME=$(cfg_val dbname)
  DBUSER=$(cfg_val dbuser)
  DBPASS=$(cfg_val dbpass)
  PREFIX=$(cfg_val prefix)
  DBPORT=$(dboption_val dbport)
  # Don't guess dirroot from config.php's folder - on newer Moodle
  # (public/ docroot) the top-level config.php is a stub that points
  # elsewhere via $CFG->dirroot, so ask PHP for the real value.
  DIRROOT=$(php -r '
    define("CLI_SCRIPT", true);
    require($argv[1]);
    echo $CFG->dirroot;
  ' "$CONFIG_FILE" 2>/dev/null)

  if [ -z "$DIRROOT" ] || [ ! -f "$DIRROOT/course/modlib.php" ]; then
    log_err "Could not determine a working Moodle dirroot from $CONFIG_FILE (looked for $DIRROOT/course/modlib.php)."
    exit 1
  fi

  [ -z "$PREFIX" ] && { log_warn "Could not read \$CFG->prefix, assuming 'mdl_'."; PREFIX="mdl_"; }

  if [ -z "$DBTYPE" ] || [ -z "$DBHOST" ] || [ -z "$DBNAME" ] || [ -z "$DBUSER" ]; then
    log_err "Could not parse DB settings out of $CONFIG_FILE. Check it manually."
    exit 1
  fi

  case "$DBTYPE" in
    mysqli|mariadb) FAMILY="mysql"; [ -z "$DBPORT" ] && DBPORT=3306 ;;
    pgsql)          FAMILY="pgsql"; [ -z "$DBPORT" ] && DBPORT=5432 ;;
    *) log_err "Unsupported dbtype '$DBTYPE' (only mysqli/mariadb/pgsql are supported)."; exit 1 ;;
  esac

  log_ok "Moodle dirroot : $DIRROOT"
  log_ok "Database       : $FAMILY://$DBUSER@$DBHOST:$DBPORT/$DBNAME (prefix: $PREFIX)"
}

check_deps() {
  local missing=()
  command -v php >/dev/null 2>&1 || missing+=("php-cli")
  command -v gzip >/dev/null 2>&1 || missing+=("gzip")
  if [ "$FAMILY" = "mysql" ]; then
    command -v mysql >/dev/null 2>&1 || missing+=("default-mysql-client")
    command -v mysqldump >/dev/null 2>&1 || missing+=("default-mysql-client")
  else
    command -v psql >/dev/null 2>&1 || missing+=("postgresql-client")
    command -v pg_dump >/dev/null 2>&1 || missing+=("postgresql-client")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    log_err "Missing tools: $(printf '%s ' "${missing[@]}")"
    log_err "Install with: sudo apt-get install $(printf '%s ' "${missing[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    exit 1
  fi
}

# ---------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------
db_query() {
  # $1 = SQL, prints tab-separated rows, no header
  if [ "$FAMILY" = "mysql" ]; then
    MYSQL_PWD="$DBPASS" mysql -N -B -h "$DBHOST" -P "$DBPORT" -u "$DBUSER" "$DBNAME" -e "$1" 2>/dev/null
  else
    PGPASSWORD="$DBPASS" psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$DBNAME" -At -F $'\t' -c "$1" 2>/dev/null
  fi
}

do_backup() {
  local ts dumpfile
  ts=$(date +%Y%m%d_%H%M%S)
  dumpfile="moodle_${DBNAME}_${ts}.sql.gz"
  log_info "Backing up database '$DBNAME' to $dumpfile ..."
  if [ "$FAMILY" = "mysql" ]; then
    MYSQL_PWD="$DBPASS" mysqldump --no-tablespaces -h "$DBHOST" -P "$DBPORT" -u "$DBUSER" "$DBNAME" | gzip > "$dumpfile"
  else
    PGPASSWORD="$DBPASS" pg_dump -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$DBNAME" --clean --if-exists | gzip > "$dumpfile"
  fi
  if [ "${PIPESTATUS[0]}" -ne 0 ] || [ ! -s "$dumpfile" ]; then
    log_err "Backup failed - refusing to touch the database without a good backup."
    rm -f "$dumpfile"
    exit 1
  fi
  log_ok "Backup complete: $dumpfile ($(du -h "$dumpfile" | cut -f1))"
  DUMPFILE="$dumpfile"
}

restore_from_file() {
  local file="$1"
  log_info "Restoring $file into '$DBNAME' ..."
  if [ "$FAMILY" = "mysql" ]; then
    gunzip -c "$file" | MYSQL_PWD="$DBPASS" mysql -h "$DBHOST" -P "$DBPORT" -u "$DBUSER" "$DBNAME"
  else
    gunzip -c "$file" | PGPASSWORD="$DBPASS" psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -d "$DBNAME" -v ON_ERROR_STOP=1
  fi
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_err "Restore failed. Database may be in a partial state - restore manually from $file."
    exit 1
  fi
  log_ok "Restore complete."
}

# ---------------------------------------------------------------------
# list assignments, prompt for cmids
# ---------------------------------------------------------------------
list_assignments() {
  log_info "Current assignments:"
  local sql="SELECT cm.id, c.shortname, a.name
             FROM ${PREFIX}course_modules cm
             JOIN ${PREFIX}modules m ON m.id = cm.module AND m.name = 'assign'
             JOIN ${PREFIX}assign a ON a.id = cm.instance
             JOIN ${PREFIX}course c ON c.id = cm.course
             ORDER BY c.shortname, cm.id;"
  local rows
  rows=$(db_query "$sql")
  if [ -z "$rows" ]; then
    log_warn "Could not list assignments automatically (or there are none). You can still enter cmids manually."
    return
  fi
  printf '%s\n' "$rows" | awk -F'\t' '{printf "  cmid %-6s [%-15s] %s\n", $1, $2, $3}'
}

prompt_for_cmids() {
  local raw
  read -rp "Enter the cmid(s) to convert (space or comma separated): " raw
  raw="${raw//,/ }"
  CMIDS=()
  for tok in $raw; do
    if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
      log_err "'$tok' is not a valid numeric cmid. Aborting."
      exit 1
    fi
    CMIDS+=("$tok")
  done
  if [ ${#CMIDS[@]} -eq 0 ]; then
    log_err "No cmids entered."
    exit 1
  fi
}

# ---------------------------------------------------------------------
# run the actual conversion via a generated PHP helper (uses Moodle's own
# add_moduleinfo()/course_delete_module() APIs for correctness)
# ---------------------------------------------------------------------
run_conversion() {
  local csv
  csv=$(printf '%s,' "${CMIDS[@]}")
  csv="${csv%,}"

  TMP_PHP=$(mktemp /tmp/assign2page.XXXXXX.php)

  cat > "$TMP_PHP" <<'PHPEOF'
<?php
define('CLI_SCRIPT', true);
require '__CONFIG_PATH__';
require_once($CFG->dirroot . '/course/modlib.php');
require_once($CFG->dirroot . '/course/lib.php');

global $DB, $USER;
$USER = get_admin();

$cmids = [__CMID_LIST__];
$deleteoriginal = true;

$exitcode = 0;
$lastcourseid = null;

foreach ($cmids as $cmid) {
    try {
        $cm      = get_coursemodule_from_id('assign', $cmid, 0, false, MUST_EXIST);
        $course  = $DB->get_record('course', ['id' => $cm->course], '*', MUST_EXIST);
        $assign  = $DB->get_record('assign', ['id' => $cm->instance], '*', MUST_EXIST);
        $section = $DB->get_record('course_sections', ['id' => $cm->section], '*', MUST_EXIST);
        $context = context_module::instance($cm->id);
        $lastcourseid = $course->id;

        $draftitemid = file_get_unused_draft_itemid();
        $content = file_prepare_draft_area(
            $draftitemid, $context->id, 'mod_assign', 'intro', $assign->id, null, $assign->intro
        );

        $moduleinfo = new stdClass();
        $moduleinfo->modulename         = 'page';
        $moduleinfo->course             = $course->id;
        $moduleinfo->section            = $section->section;
        $moduleinfo->visible            = $cm->visible;
        $moduleinfo->name               = $assign->name;
        $moduleinfo->intro              = '';
        $moduleinfo->introformat        = FORMAT_HTML;
        $moduleinfo->page               = [
            'text'   => $content,
            'format' => $assign->introformat,
            'itemid' => $draftitemid,
        ];
        $moduleinfo->printintro         = 0;
        $moduleinfo->printlastmodified  = 0;
        $moduleinfo->completion         = COMPLETION_TRACKING_MANUAL;
        $moduleinfo->completionview     = 0;
        $moduleinfo->completionexpected = 0;
        $moduleinfo->beforemod          = $cm->id;

        list($newcm, ) = add_moduleinfo($moduleinfo, $course);
        mtrace("OK   cmid={$cm->id} \"{$assign->name}\" -> new Textseite cmid={$newcm->id}");

        if ($deleteoriginal) {
            course_delete_module($cm->id);
            mtrace("     deleted original assignment cmid={$cm->id}");
        }
    } catch (Throwable $e) {
        mtrace("FAIL cmid={$cmid}: " . $e->getMessage());
        $exitcode = 1;
    }
}

if ($lastcourseid !== null) {
    rebuild_course_cache($lastcourseid, true);
}
mtrace('Done.');
exit($exitcode);
PHPEOF

  # inject the discovered config path and chosen cmids (avoids fighting
  # bash's own $-expansion inside the heredoc above)
  local escaped_path="${CONFIG_FILE//\//\\/}"
  sed -i "s/__CONFIG_PATH__/${escaped_path}/" "$TMP_PHP"
  sed -i "s/__CMID_LIST__/${csv}/" "$TMP_PHP"

  log_info "Running conversion for cmids: ${CMIDS[*]}"
  php "$TMP_PHP"
  local rc=$?

  if [ $rc -ne 0 ]; then
    log_err "Conversion reported at least one failure (see FAIL lines above)."
    if confirm "Restore the database from the backup taken at the start of this run ($DUMPFILE)?" Y; then
      restore_from_file "$DUMPFILE"
    else
      log_warn "Left as-is. Restore later with: ./$(basename "$0") --restore"
    fi
    exit 1
  fi

  log_ok "Conversion finished successfully."
}

# ---------------------------------------------------------------------
# --restore mode
# ---------------------------------------------------------------------
do_restore_mode() {
  discover_config
  parse_config
  check_deps

  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t ./*.sql.gz 2>/dev/null)

  if [ ${#files[@]} -eq 0 ]; then
    log_err "No *.sql.gz dump files found in $(pwd)."
    exit 1
  fi

  echo "Dump files in $(pwd):"
  local i=1
  for f in "${files[@]}"; do
    printf "  %d) %-45s %8s  %s\n" "$i" "$f" "$(du -h "$f" | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    i=$((i+1))
  done

  local sel
  read -rp "Which file to restore? [1-${#files[@]}]: " sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#files[@]} ]; then
    log_err "Invalid selection."
    exit 1
  fi
  local file="${files[$((sel-1))]}"

  if ! confirm "This will OVERWRITE the current database '$DBNAME' with $file. Continue?"; then
    log_info "Cancelled."
    exit 0
  fi
  restore_from_file "$file"
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------
main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --restore) do_restore_mode; exit 0 ;;
  esac

  discover_config
  parse_config
  check_deps

  echo
  log_warn "About to back up '$DBNAME', then convert selected assignments to Textseite (Page) activities with manual completion, deleting the originals."
  confirm "Proceed?" Y || { log_info "Cancelled."; exit 0; }

  do_backup
  echo
  list_assignments
  echo
  prompt_for_cmids

  echo
  echo "Selected cmids: ${CMIDS[*]}"
  confirm "Convert these now?" Y || { log_info "Cancelled. Backup kept at $DUMPFILE."; exit 0; }

  run_conversion
}

main "$@"
