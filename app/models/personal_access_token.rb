# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require "digest"

class PersonalAccessToken < ApplicationRecord
  TOKEN_PREFIX = 'redmine-pat-'

  belongs_to :user

  validates_presence_of :name, :expires_on
  validates_uniqueness_of :name, scope: :user_id

  # One-time raw token value, only available right after the record is
  # created. Never persisted: only its SHA256 digest is stored in
  # token_digest.
  attr_accessor :value

  before_create :generate_token

  # Finds the PersonalAccessToken matching the given raw token value, or nil
  def self.find_by_value(raw_value)
    digest = Digest::SHA256.hexdigest(raw_value.to_s)
    token = find_by(token_digest: digest)
    return nil unless token
    return nil unless ActiveSupport::SecurityUtils.secure_compare(token.token_digest, digest)

    token
  end

  # Returns true if the token has expired
  def expired?
    expires_on < Date.today
  end

  # Returns the list of permission names this token is restricted to, as an
  # array of symbols, or nil if the token is unrestricted (same privileges as
  # the user's roles).
  def scope_list
    return nil if scopes.blank?

    scopes.to_s.split.map(&:to_sym)
  end

  # Updates last_used_on without running validations/callbacks
  def touch_last_used!
    update_column(:last_used_on, Time.now)
  end

  private

  def generate_token
    self.value = "#{TOKEN_PREFIX}#{Redmine::Utils.random_hex(20)}"
    self.token_digest = Digest::SHA256.hexdigest(value)
  end
end
