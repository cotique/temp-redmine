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

require_relative '../../test_helper'

class Redmine::ApiTest::AuthenticationTest < Redmine::ApiTest::Base
  def teardown
    User.current = nil
  end

  def test_api_should_deny_without_credentials
    get '/users/current.xml'
    assert_response :unauthorized
    assert response.headers.has_key?('WWW-Authenticate')
  end

  def test_api_should_accept_http_basic_auth_using_username_and_password
    user = User.generate! do |user|
      user.password = 'my_password'
    end
    get '/users/current.xml', :headers => credentials(user.login, 'my_password')
    assert_response :ok
  end

  def test_api_should_deny_http_basic_auth_using_username_and_wrong_password
    user = User.generate! do |user|
      user.password = 'my_password'
    end
    get '/users/current.xml', :headers => credentials(user.login, 'wrong_password')
    assert_response :unauthorized
  end

  def test_api_should_deny_http_basic_auth_if_twofa_is_active
    user = User.generate! do |user|
      user.password = 'my_password'
      user.update(twofa_scheme: 'totp')
    end
    get '/users/current.xml', :headers => credentials(user.login, 'my_password')
    assert_response :unauthorized
  end

  def test_api_should_accept_http_basic_auth_using_api_key
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get '/users/current.xml', :headers => credentials(token.value, 'X')
    assert_response :ok
  end

  def test_api_should_deny_http_basic_auth_using_wrong_api_key
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get '/users/current.xml', :headers => credentials(token.value, 'X')
    assert_response :unauthorized
  end

  def test_api_should_accept_http_basic_auth_using_personal_access_token
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'my token', :expires_on => 30.days.from_now)
    get '/users/current.xml', :headers => credentials(pat.value, 'X')
    assert_response :ok
  end

  def test_api_should_deny_http_basic_auth_using_revoked_personal_access_token
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'revoked token', :expires_on => 30.days.from_now)
    value = pat.value
    pat.destroy
    get '/users/current.xml', :headers => credentials(value, 'X')
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_api_key_as_parameter
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get "/users/current.xml?key=#{token.value}"
    assert_response :ok
  end

  def test_api_should_deny_auth_using_wrong_api_key_as_parameter
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get "/users/current.xml?key=#{token.value}"
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_personal_access_token_as_parameter
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'my token', :expires_on => 30.days.from_now)
    get "/users/current.xml?key=#{pat.value}"
    assert_response :ok
  end

  def test_api_should_deny_auth_using_expired_personal_access_token_as_parameter
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'expired token', :expires_on => 30.days.from_now)
    # Simulate the token having expired since creation (expires_on cannot be set
    # to a past date at creation time), bypassing validations/callbacks the same
    # way touch_last_used! does.
    pat.update_column(:expires_on, 1.day.ago)
    get "/users/current.xml?key=#{pat.value}"
    assert_response :unauthorized
  end

  def test_api_should_deny_auth_using_revoked_personal_access_token_as_parameter
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'revoked token', :expires_on => 30.days.from_now)
    value = pat.value
    pat.destroy
    get "/users/current.xml?key=#{value}"
    assert_response :unauthorized
  end

  # Regression check: legacy API keys (Token#action == 'api') must keep authenticating
  # unchanged now that find_current_user/find_user_by_pat_or_api_key also resolve PATs.
  def test_api_should_accept_auth_using_legacy_api_key_as_parameter_after_personal_access_token_support
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get "/users/current.xml?key=#{token.value}"
    assert_response :ok
  end

  def test_api_should_accept_auth_using_api_key_as_request_header
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get "/users/current.xml", :headers => {'X-Redmine-API-Key' => token.value.to_s}
    assert_response :ok
  end

  def test_api_should_deny_auth_using_wrong_api_key_as_request_header
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get "/users/current.xml", :headers => {'X-Redmine-API-Key' => token.value.to_s}
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_personal_access_token_as_request_header
    user = User.generate!
    pat = PersonalAccessToken.create!(:user => user, :name => 'my token', :expires_on => 30.days.from_now)
    get "/users/current.xml", :headers => {'X-Redmine-API-Key' => pat.value.to_s}
    assert_response :ok
  end

  # jsmith (user #2) is a Manager (roles_001) on project #1 / eCookbook
  # (members_001, member_roles_001). That role has :view_issues but neither
  # :edit_issue_notes nor :edit_own_issue_notes, which makes it a small, known
  # permission set to prove PAT scope restriction against real fixtures rather
  # than inventing a new project/role.
  def test_api_should_accept_auth_using_personal_access_token_scoped_to_a_permission_the_role_has
    user = User.find(2)
    pat =
      PersonalAccessToken.create!(
        :user => user, :name => 'view issues scope',
        :expires_on => 30.days.from_now, :scopes => 'view_issues')
    get "/issues/1.xml?key=#{pat.value}"
    assert_response :ok
  end

  # Manager also has :log_time, so a PAT scoped down to only that permission
  # proves the scope actively narrows access below the role's real grant,
  # rather than merely mirroring a permission the role never had at all.
  def test_api_should_deny_auth_using_personal_access_token_scoped_away_from_a_permission_the_role_has
    user = User.find(2)
    pat =
      PersonalAccessToken.create!(
        :user => user, :name => 'log time only scope',
        :expires_on => 30.days.from_now, :scopes => 'log_time')
    get "/issues/1.xml?key=#{pat.value}"
    assert_response :forbidden
  end

  def test_api_should_deny_auth_using_personal_access_token_scoped_to_a_permission_the_role_lacks
    user = User.find(2)
    pat =
      PersonalAccessToken.create!(
        :user => user, :name => 'edit issue notes scope',
        :expires_on => 30.days.from_now, :scopes => 'edit_issue_notes')
    put(
      '/journals/1.xml',
      :params => {:journal => {:notes => 'changed via scoped PAT'}},
      :headers => {'X-Redmine-API-Key' => pat.value.to_s})
    assert_response :forbidden
  end

  def test_api_should_trigger_basic_http_auth_with_basic_authorization_header
    ApplicationController.any_instance.expects(:authenticate_with_http_basic).once
    get '/users/current.xml', :headers => credentials('jsmith')
    assert_response :unauthorized
  end

  def test_api_should_not_trigger_basic_http_auth_with_non_basic_authorization_header
    ApplicationController.any_instance.expects(:authenticate_with_http_basic).never
    get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => 'Digest foo bar'}
    assert_response :unauthorized
  end

  def test_invalid_utf8_credentials_should_not_trigger_an_error
    invalid_utf8 = "\x82"
    assert !invalid_utf8.valid_encoding?
    assert_nothing_raised do
      get '/users/current.xml', :headers => credentials(invalid_utf8, "foo")
    end
  end

  def test_api_request_should_not_use_user_session
    log_user('jsmith', 'jsmith')

    get '/users/current'
    assert_response :success

    get '/users/current.json'
    assert_response :unauthorized
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_accept_switch_user_header_for_admin_user
    user = User.find(1)
    su = User.find(4)

    get '/users/current', :headers => {'X-Redmine-API-Key' => user.api_key, 'X-Redmine-Switch-User' => su.login}
    assert_response :success
    assert_select 'h2', :text => "#{su.initials} #{su.name}"
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_respond_with_412_when_trying_to_switch_to_a_invalid_user
    get '/users/current', :headers => {'X-Redmine-API-Key' => User.find(1).api_key, 'X-Redmine-Switch-User' => 'foobar'}
    assert_response :precondition_failed
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_respond_with_412_when_trying_to_switch_to_a_locked_user
    user = User.find(5)
    assert user.locked?

    get '/users/current', :headers => {'X-Redmine-API-Key' => User.find(1).api_key, 'X-Redmine-Switch-User' => user.login}
    assert_response :precondition_failed
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_not_accept_switch_user_header_for_non_admin_user
    user = User.find(2)
    su = User.find(4)

    get '/users/current', :headers => {'X-Redmine-API-Key' => user.api_key, 'X-Redmine-Switch-User' => su.login}
    assert_response :success
    assert_select 'h2', :text => "#{user.initials} #{user.name}"
  end
end
