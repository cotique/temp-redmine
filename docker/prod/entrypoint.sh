#!/bin/sh
set -e

db_path="${REDMINE_DB_PATH:-db/redmine.sqlite3}"
mkdir -p "$(dirname "$db_path")"

bundle exec rake db:prepare

exec "$@"
