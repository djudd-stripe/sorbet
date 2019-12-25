# frozen_string_literal: true

require 'rake/task'
require_relative 'getters'
require_relative 'deserialize'
require_relative 'prop_definition'

namespace :bench do
  task :getters do
    SorbetBenchmarks::Getters.run
  end

  task :deserialize do
    SorbetBenchmarks::Deserialize.run
  end

  task :prop_definition do
    SorbetBenchmarks::PropDefinition.run
  end
end
