Given('I have two numbers {int} and {int}') do |int, int2|
  @int = int
  @int2 = int2
end

When('I add them') do
  @result = @int + @int2
end

Then('the result should be {int}') do |expected_result|
  expect(@result).to eq(expected_result)
end
