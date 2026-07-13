#!/usr/bin/env bash

set -euo pipefail

BACKUP_DIR="/backups"
PG_HOST="localhost"
PG_PORT="5432"
PG_USER="postgres"
RETENTION_DAYS=14
DATABASES=""
COMPRESS_LEVEL=6
LOG_FILE="/var/log/pg_backup.log"
LOCK_FILE="/tmp/pg_backup.lock"
EXCLUDE_DBS="template0|template1"

TEMP_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OVERALL_SUCCESS=true
TOTAL_DB=0
SUCCESS_DB=0
FAILED_DB=0
SKIPPED_DB=0

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[${timestamp}] [${level}] ${message}"

    echo "${log_line}" >> "${LOG_FILE}"

    case "${level}" in
        INFO)    echo -e "${GREEN}${log_line}${NC}" ;;
        WARN)    echo -e "${YELLOW}${log_line}${NC}" ;;
        ERROR)   echo -e "${RED}${log_line}${NC}" ;;
        *)       echo "${log_line}" ;;
    esac
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

cleanup() {
    local exit_code=$?
    if [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
        log_info "Временный каталог ${TEMP_DIR} удалён"
    fi

    if [[ -f "${LOCK_FILE}" ]]; then
        rm -f "${LOCK_FILE}"
    fi

    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Скрипт завершился с ошибкой (код: ${exit_code})"
    fi
}

trap cleanup EXIT

abort_db() {
    local db="$1"
    local reason="$2"
    log_error "Бэкап базы '${db}' прерван: ${reason}"
    OVERALL_SUCCESS=false
    ((FAILED_DB++)) || true
    rm -f "${TEMP_DIR}/${db}".dump* 2>/dev/null || true
}

check_dependencies() {
    local missing=()

    for cmd in pg_dump psql gzip; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Не найдены утилиты: ${missing[*]}"
        log_error "Установите PostgreSQL client: apt install postgresql-client / yum install postgresql"
        exit 1
    fi
}

check_pg_connection() {
    log_info "Проверка подключения к PostgreSQL (${PG_HOST}:${PG_PORT}, пользователь: ${PG_USER})..."

    if ! psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "SELECT 1;" &>/dev/null; then
        log_error "Не удалось подключиться к PostgreSQL"
        log_error "Проверьте: доступность сервера, порт, пользователя, файл ~/.pgpass"
        exit 1
    fi

    log_info "Подключение к PostgreSQL установлено успешно"
}

get_database_list() {
    if [[ -n "${DATABASES}" ]]; then
        echo "${DATABASES}" | tr ',' '\n'
        return
    fi

    local db_list
    if ! db_list=$(psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -t -A \
        -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" 2>&1); then
        log_error "Не удалось получить список баз данных: ${db_list}"
        exit 1
    fi

    echo "${db_list}"
}

check_disk_space() {
    local target_dir="$1"
    local min_space_mb="${2:-500}"  # минимум 500 МБ

    local available_mb
    available_mb=$(df -m "${target_dir}" | awk 'NR==2 {print $4}')

    if [[ -z "${available_mb}" ]]; then
        log_warn "Не удалось определить свободное место на диске ${target_dir}"
        return 0
    fi

    if [[ ${available_mb} -lt ${min_space_mb} ]]; then
        log_error "Недостаточно свободного места на диске: ${available_mb} МБ доступно, нужно минимум ${min_space_mb} МБ"
        return 1
    fi

    log_info "Свободное место на диске: ${available_mb} МБ"
    return 0
}

verify_archive() {
    local archive="$1"

    if ! gzip -t "${archive}" 2>/dev/null; then
        log_error "Проверка целостности архива ${archive} не пройдена — архив повреждён"
        return 1
    fi

    log_info "Целостность архива ${archive} подтверждена"
    return 0
}

cleanup_old_backups() {
    local target_dir="$1"
    local retention_days="$2"

    log_info "Очистка бэкапов старше ${retention_days} дней в ${target_dir}..."

    local deleted_count=0
    while IFS= read -r -d '' old_file; do
        rm -f "${old_file}"
        log_info "Удалён устаревший бэкап: $(basename "${old_file}")"
        ((deleted_count++)) || true
    done < <(find "${target_dir}" -maxdepth 1 -name "pg_backup_*.sql.gz" -type f -mtime +"${retention_days}" -print0 2>/dev/null)

    if [[ ${deleted_count} -eq 0 ]]; then
        log_info "Устаревших бэкапов для удаления нет"
    else
        log_info "Удалено устаревших бэкапов: ${deleted_count}"
    fi
}

backup_database() {
    local db="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local dump_file="${TEMP_DIR}/${db}_${timestamp}.dump"
    local archive_file="${BACKUP_DIR}/pg_backup_${db}_${timestamp}.sql.gz"

    log_info "──────────────────────────────────────"
    log_info "Начало бэкапа базы: ${db}"

    log_info "Создание дампа базы '${db}'..."
    if ! pg_dump -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" \
        -Fc --no-owner --no-privileges \
        -f "${dump_file}" "${db}" 2>>"${LOG_FILE}"; then
        abort_db "${db}" "ошибка при создании дампа"
        return
    fi

    if [[ ! -s "${dump_file}" ]]; then
        abort_db "${db}" "дамп пуст или не был создан"
        return
    fi

    local dump_size
    dump_size=$(du -h "${dump_file}" | cut -f1)
    log_info "Дамп создан: ${dump_size}"

    log_info "Сжатие дампа (gzip -${COMPRESS_LEVEL})..."
    if ! gzip -"${COMPRESS_LEVEL}" "${dump_file}" 2>>"${LOG_FILE}"; then
        abort_db "${db}" "ошибка при сжатии дампа"
        return
    fi

    local compressed_file="${dump_file}.gz"
    if [[ ! -f "${compressed_file}" ]]; then
        compressed_file=$(ls "${TEMP_DIR}/${db}_${timestamp}".dump*.gz 2>/dev/null | head -1)
    fi

    if [[ ! -s "${compressed_file}" ]]; then
        abort_db "${db}" "сжатый архив пуст или не был создан"
        return
    fi

    local compressed_size
    compressed_size=$(du -h "${compressed_file}" | cut -f1)
    log_info "Архив создан: ${compressed_size}"

    log_info "Проверка целостности архива..."
    if ! verify_archive "${compressed_file}"; then
        abort_db "${db}" "архив повреждён"
        return
    fi

    log_info "Перенос архива в ${BACKUP_DIR}..."
    local final_archive="${BACKUP_DIR}/pg_backup_${db}_${timestamp}.sql.gz"
    if ! mv "${compressed_file}" "${final_archive}"; then
        abort_db "${db}" "ошибка при переносе архива в ${BACKUP_DIR}"
        return
    fi

    local final_size
    final_size=$(du -h "${final_archive}" | cut -f1)
    log_info "Бэкап базы '${db}' завершён успешно: ${final_archive} (${final_size})"

    ((SUCCESS_DB++)) || true
}

print_summary() {
    echo ""
    log_info "══════════════════════════════════════"
    log_info "ИТОГИ РЕЗЕРВНОГО КОПИРОВАНИЯ"
    log_info "══════════════════════════════════════"
    log_info "Всего баз:        ${TOTAL_DB}"
    log_info "Успешно:          ${SUCCESS_DB}"
    log_info "Ошибок:           ${FAILED_DB}"
    log_info "Пропущено:        ${SKIPPED_DB}"
    log_info "Каталог бэкапов:  ${BACKUP_DIR}"
    log_info "Лог-файл:         ${LOG_FILE}"

    if [[ "${OVERALL_SUCCESS}" == "true" ]]; then
        log_info "Статус: ВСЕ БЭКАПЫ ВЫПОЛНЕНЫ УСПЕШНО"
    else
        log_error "Статус: ЕСТЬ ОШИБКИ — проверьте лог-файл"
    fi

    log_info "══════════════════════════════════════"
}

usage() {
    echo "Использование: $(basename "$0") [ОПЦИИ]"
    echo ""
    echo "Опции:"
    echo "  -h HOST      Хост PostgreSQL (по умолчанию: localhost)"
    echo "  -p PORT      Порт PostgreSQL (по умолчанию: 5432)"
    echo "  -u USER      Пользователь PostgreSQL (по умолчанию: postgres)"
    echo "  -d DB        База данных (через запятую для нескольких). По умолчанию — все."
    echo "  -b DIR       Каталог для бэкапов (по умолчанию: /backups)"
    echo "  -r DAYS      Срок хранения бэкапов в днях (по умолчанию: 14)"
    echo "  -l FILE      Путь к лог-файлу (по умолчанию: /var/log/pg_backup.log)"
    echo "  -e PATTERN   Исключить базы по шаблону grep (по умолчанию: template0|template1)"
    echo "  -?           Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $(basename "$0")                                    # Бэкап всех баз"
    echo "  $(basename "$0") -d mydb,analytics                  # Бэкап двух баз"
    echo "  $(basename "$0") -h db.example.com -p 5433 -u ops  # Удалённый сервер"
    echo "  $(basename "$0") -r 7 -b /mnt/nas/backups         # 7 дней, на NAS"
}

parse_args() {
    while getopts "h:p:u:d:b:r:l:e:?" opt; do
        case "${opt}" in
            h) PG_HOST="${OPTARG}" ;;
            p) PG_PORT="${OPTARG}" ;;
            u) PG_USER="${OPTARG}" ;;
            d) DATABASES="${OPTARG}" ;;
            b) BACKUP_DIR="${OPTARG}" ;;
            r) RETENTION_DAYS="${OPTARG}" ;;
            l) LOG_FILE="${OPTARG}" ;;
            e) EXCLUDE_DBS="${OPTARG}" ;;
            ?|*) usage; exit 0 ;;
        esac
    done
}

main() {
    parse_args "$@"

    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || {
        echo "Не удалось создать лог-файл ${LOG_FILE}. Проверьте права."
        exit 1
    }

    log_info "══════════════════════════════════════"
    log_info "ЗАПУСК СКРИПТА РЕЗЕРВНОГО КОПИРОВАНИЯ"
    log_info "Сервер: ${PG_HOST}:${PG_PORT}"
    log_info "Пользователь: ${PG_USER}"
    log_info "Каталог бэкапов: ${BACKUP_DIR}"
    log_info "Хранение: ${RETENTION_DAYS} дней"
    log_info "══════════════════════════════════════"

    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCK_FILE}" 2>/dev/null)
        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Скрипт уже запущен (PID: ${lock_pid}). Параллельные запуски запрещены."
            exit 1
        else
            log_warn "Найден устаревший lock-файл (процесс ${lock_pid} не активен). Удаляем."
            rm -f "${LOCK_FILE}"
        fi
    fi

    echo $$ > "${LOCK_FILE}"

    check_dependencies

    check_pg_connection

    mkdir -p "${BACKUP_DIR}" || {
        log_error "Не удалось создать каталог бэкапов: ${BACKUP_DIR}"
        exit 1
    }

    TEMP_DIR=$(mktemp -d "${HOME}/.pg_backup_tmp.XXXXXX") || {
        log_error "Не удалось создать временный каталог"
        exit 1
    }
    log_info "Временный каталог: ${TEMP_DIR}"

    if ! check_disk_space "${BACKUP_DIR}" 500; then
        log_error "Недостаточно места для создания бэкапов. Прерываем."
        exit 1
    fi

    log_info "Получение списка баз данных..."
    local db_list
    db_list=$(get_database_list)

    if [[ -z "${db_list}" ]]; then
        log_warn "Не найдено ни одной базы данных для бэкапа"
        exit 0
    fi

    local filtered_list=""
    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        if echo "${db}" | grep -qEi "${EXCLUDE_DBS}"; then
            log_info "Пропуск служебной базы: ${db}"
            ((SKIPPED_DB++)) || true
            continue
        fi
        filtered_list+="${db}"$'\n'
    done <<< "${db_list}"

    filtered_list=$(echo "${filtered_list}" | sed '/^$/d')

    if [[ -z "${filtered_list}" ]]; then
        log_warn "После фильтрации не осталось баз для бэкапа"
        exit 0
    fi

    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        ((TOTAL_DB++)) || true
        backup_database "${db}"
    done <<< "${filtered_list}"

    cleanup_old_backups "${BACKUP_DIR}" "${RETENTION_DAYS}"

    print_summary

    if [[ "${OVERALL_SUCCESS}" == "false" ]]; then
        exit 1
    fi
}

main "$@"
