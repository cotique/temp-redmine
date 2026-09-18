FROM ruby:3.3-slim

# rubocop's `prism` parser dependency needs to compile a C extension.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the versions this repo's Gemfile asks for (test group), so
# results match what `bundle exec rubocop` would report once a native
# Ruby/Bundler toolchain exists on the host. No Rails/DB gems here on
# purpose — the dod-gate/format-postcheck hooks only need rubocop itself.
RUN gem install --no-document \
    'rubocop:1.91.0' \
    'rubocop-performance:1.27.0' \
    'rubocop-rails:2.37.0'

WORKDIR /repo
ENTRYPOINT ["rubocop"]
