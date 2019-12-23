# frozen_string_literal: true

require 'rake/task'
require_relative 'getters'

namespace :bench do
  task :getters do
    SorbetBenchmarks::Getters.run
  end
end
