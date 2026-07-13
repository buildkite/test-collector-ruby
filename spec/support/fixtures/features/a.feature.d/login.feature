Feature: Login
  Scenario: Simple login
    Given I have a valid account
    When I log in
    Then I should be logged in
