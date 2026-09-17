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
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    assert pat.value.present?
    assert_not_equal pat.value, pat.token_digest
    assert_equal Digest::SHA256.hexdigest(pat.value), pat.token_digest
  end

  def test_expires_on_cannot_be_in_the_past
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => 1.day.ago.to_date)
    assert !pat.save
    assert_includes pat.errors[:expires_on], 'cannot be in the past'
  end

  def test_expires_on_today_should_be_valid
    pat = PersonalAccessToken.new(:user => @user, :name => 'test', :expires_on => Date.today)
    assert pat.save
  end

  def test_name_should_be_unique_per_user
    PersonalAccessToken.create!(:user => @user, :name => 'dup', :expires_on => 30.days.from_now)
    pat = PersonalAccessToken.new(:user => @user, :name => 'dup', :expires_on => 30.days.from_now)
    assert !pat.save
    assert_includes pat.errors[:name], 'has already been taken'
  end

  def test_find_by_value_should_return_the_matching_token
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    assert_equal pat, PersonalAccessToken.find_by_value(pat.value)
  end

  def test_find_by_value_should_return_nil_for_an_unknown_value
    assert_nil PersonalAccessToken.find_by_value('garbage')
  end

  def test_expired_should_be_false_for_a_future_expiration
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    assert !pat.expired?
  end

  def test_expired_should_be_true_once_past_expiration
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    pat.update_column(:expires_on, 1.day.ago)
    assert pat.expired?
  end

  def test_scope_list_should_be_nil_when_scopes_is_blank
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now)
    assert_nil pat.scope_list
  end

  def test_scope_list_should_split_scopes_into_symbols
    pat = PersonalAccessToken.create!(:user => @user, :name => 'test', :expires_on => 30.days.from_now,
                                       :scopes => 'view_issues edit_issues')
    assert_equal [:view_issues, :edit_issues], pat.scope_list
  end
end
