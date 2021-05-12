module FakeEnvHelpers
  def fake_env(key, value)
    allow(ENV).to receive(:[]).with(key).and_return(value)
  end
end
