# frozen_string_literal: true
# typed: true

require 'benchmark'

require_relative '../lib/sorbet-runtime'

module SorbetBenchmarks
  module Deserialize

    class Example
      include T::Props::Serializable

      class Subdoc
        include T::Props::Serializable
        prop :prop, String
      end

      prop :prop1, T.nilable(Integer)
      prop :prop2, Integer, default: 0
      prop :prop3, Integer
      prop :prop4, T::Array[Integer]
      prop :prop5, T::Array[Integer], default: []
      prop :prop6, T::Hash[String, Integer]
      prop :prop7, T::Hash[String, Integer], default: {}
      prop :prop8, T.nilable(Subdoc)
      prop :prop9, T::Array[Subdoc], default: []
      prop :prop10, T::Hash[String, Subdoc], default: {}
    end


    def self.run
      result = Benchmark.measure do
        input = {
          'prop3' => 0,
          'prop4' => [],
          'prop6' => {},
        }

        100_000.times do
          Example.from_hash(input)
        end
      end

      puts "With minimal input:"
      puts result

      result = Benchmark.measure do
        input = {
          'prop1' => 0,
          'prop2' => 0,
          'prop3' => 0,
          'prop4' => [1, 2, 3],
          'prop5' => [1, 2, 3],
          'prop6' => {'foo' => 1, 'bar' => 2},
          'prop7' => {'foo' => 1, 'bar' => 2},
          'prop8' => {'prop' => ''},
          'prop9' => [{'prop' => ''}, {'prop' => ''}],
          'prop10' => {'foo' => {'prop' => ''}, 'bar' => {'prop' => ''}},
        }

        100_000.times do
          Example.from_hash(input)
        end
      end

      puts "With larger input:"
      puts result
    end
  end
end
