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

require_relative '../test_helper'

class PersonalAccessTokenTest < ActiveSupport::TestCase
  def setup
    User.current = nil
    @user = User.find(1)
  end

  def test_create_should_generate_a_value_and_digest_it
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues')
    assert pat.value.present?
    assert_not_equal pat.value, pat.token_digest
    assert_equal Digest::SHA256.hexdigest(pat.value), pat.token_digest
  end

  def test_expires_on_cannot_be_in_the_past
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => 1.day.ago.to_date,
                                   :scopes => 'view_issues')
    assert !pat.save
    assert_includes pat.errors[:expires_on], 'cannot be in the past'
  end

  def test_expires_on_today_should_be_valid
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => Date.today,
                                   :scopes => 'view_issues')
    assert pat.save
  end

  def test_scopes_cannot_be_blank
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    with_locale('en') do
      assert !pat.save
      assert_includes pat.errors[:scopes], 'cannot be blank'
    end
  end

  def test_name_should_be_unique_per_user
    PersonalAccessToken.create!(:user => @user, :name => 'dup', :expires_on => 30.days.from_now,
                                 :scopes => 'view_issues')
    pat = PersonalAccessToken.new(:user => @user, :name => 'dup', :expires_on => 30.days.from_now,
                                   :scopes => 'view_issues')
    with_locale('en') do
      assert !pat.save
      assert_includes pat.errors[:name], 'has already been taken'
    end
  end

  def test_find_by_value_should_return_the_matching_token
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues')
    assert_equal pat, PersonalAccessToken.find_by_value(pat.value)
  end

  def test_find_by_value_should_return_nil_for_an_unknown_value
    assert_nil PersonalAccessToken.find_by_value('garbage')
  end

  def test_expired_should_be_false_for_a_future_expiration
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues')
    assert !pat.expired?
  end

  def test_expired_should_be_true_once_past_expiration
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues')
    pat.update_column(:expires_on, 1.day.ago)
    assert pat.expired?
  end

  # Blank scopes is no longer a persistable state (see test_scopes_cannot_be_blank), but
  # scope_list is a pure attribute reader - it must still behave correctly on an unsaved
  # instance, without needing to save/create it.
  def test_scope_list_should_be_nil_when_scopes_is_blank
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    assert_nil pat.scope_list
  end

  def test_scope_list_should_split_scopes_into_symbols
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues edit_issues')
    assert_equal [:view_issues, :edit_issues], pat.scope_list
  end

  def test_allowed_permissions_should_be_empty_by_default
    with_settings :personal_access_token_allowed_scopes => [] do
      assert_equal [], PersonalAccessToken.allowed_permissions
      assert_equal [], PersonalAccessToken.allowed_permission_names
    end
  end

  def test_allowed_permissions_should_be_narrowed_to_the_configured_setting
    with_settings :personal_access_token_allowed_scopes => %w(view_issues log_time) do
      assert_equal [:log_time, :view_issues], PersonalAccessToken.allowed_permission_names.sort
    end
  end

  def test_allowed_permissions_should_silently_drop_a_bogus_configured_permission_name
    with_settings :personal_access_token_allowed_scopes => %w(view_issues this_permission_does_not_exist) do
      assert_equal [:view_issues], PersonalAccessToken.allowed_permission_names
    end
  end

  # An unrestricted (blank-scope) token is no longer a persistable state (see
  # test_scopes_cannot_be_blank), but effective_scope_list/scopes_disabled? are pure
  # attribute readers - built on an unsaved instance here, with no save/create needed.
  def test_effective_scope_list_should_be_nil_for_an_unrestricted_token_regardless_of_allow_list
    with_settings :personal_access_token_allowed_scopes => [] do
      pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
      assert_nil pat.effective_scope_list
      assert !pat.scopes_disabled?
    end
  end

  def test_effective_scope_list_should_be_non_empty_when_the_scope_is_currently_allowed
    with_settings :personal_access_token_allowed_scopes => %w(view_issues) do
      pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                         :scopes => 'view_issues')
      assert_equal [:view_issues], pat.effective_scope_list
      assert !pat.scopes_disabled?
    end
  end

  def test_effective_scope_list_should_be_empty_when_the_scope_is_no_longer_allowed
    with_settings :personal_access_token_allowed_scopes => [] do
      pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                         :scopes => 'view_issues')
      assert_equal [], pat.effective_scope_list
      assert pat.scopes_disabled?
    end
  end
end
