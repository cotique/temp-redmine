FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      libsqlite3-dev \
      libxml2-dev \
      libxslt1-dev \
      zlib1g-dev \
      git \
      curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/redmine

ENV RAILS_ENV=production \
    REDMINE_LANG=en \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="minimagick:development:test"
# `ldap` isn't excluded even though this deployment doesn't use LDAP: app/models/
# auth_source_ldap.rb does a hard `require "net/ldap"` at load time, and production's
# eager_load pulls in every file under app/ at boot - unlike minimagick, which only
# ever does a safe `const_defined?` check, so it can stay excluded.

# database.yml only needs a real adapter name at build time - the Gemfile reads it to
# decide which db gem to install. The actual sqlite3 file path is resolved from
# REDMINE_DB_PATH at runtime (see entrypoint.sh), since Cloud Run mounts the GCS volume
# at a path that isn't known until deploy time.
COPY docker/prod/database.yml config/database.yml

# Gemfile.lock is gitignored in this repo (never committed - CI always resolves fresh,
# see .github/workflows/linters.yml/tests.yml), so it won't exist in a clean checkout.
# Only copy Gemfile and let `bundle install` do a fresh resolution here too.
COPY Gemfile ./
RUN bundle install --jobs "$(nproc)"

COPY . .
# Re-copy over the checked-out config/database.yml (it's gitignored, so `COPY . .` above
# doesn't touch it - this line is just cheap insurance if that ever changes).
COPY docker/prod/database.yml config/database.yml

RUN bundle exec rake generate_secret_token

RUN bundle exec rake assets:precompile

COPY docker/prod/entrypoint.sh /usr/local/bin/redmine-entrypoint
RUN chmod +x /usr/local/bin/redmine-entrypoint

EXPOSE 8080
ENTRYPOINT ["redmine-entrypoint"]
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8080"]
