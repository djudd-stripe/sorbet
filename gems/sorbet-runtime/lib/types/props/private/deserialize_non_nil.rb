# frozen_string_literal: true
# typed: strict

module T::Props
  module Private
    module DeserializeNonNil
      extend T::Sig

      TrustedRuby = RubyGen::TrustedRuby

      INPUT_VARNAME = T.let(TrustedRuby.constant('val'), TrustedRuby)
      KEY_VARNAME = T.let(TrustedRuby.constant('k'), TrustedRuby)
      VALUE_VARNAME = T.let(TrustedRuby.constant('v'), TrustedRuby)

      class HasVarname < RubyGen::Template
        abstract!

        sig {params(name: TrustedRuby).returns(TrustedRuby).checked(:never)}
        def self.generate(name)
          new(name: name).generate
        end
      end

      class HasVarnameAndInner < RubyGen::Template
        abstract!

        sig {params(name: TrustedRuby, inner: TrustedRuby).returns(TrustedRuby).checked(:never)}
        def self.generate(name, inner)
          new(name: name, inner: inner).generate
        end
      end

      class HasVarnameAndSubtype < RubyGen::Template
        abstract!

        sig {params(name: TrustedRuby, subtype: Module).returns(TrustedRuby).checked(:never)}
        def self.generate(name, subtype)
          new(name: name, subtype: RubyGen::ModuleLiteral.new(subtype)).generate
        end
      end

      class None < HasVarname
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s'
        end
      end

      class Dup < HasVarname
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.dup'
        end
      end

      class DeserializeProps < HasVarnameAndSubtype
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            %<subtype>s.from_hash(%<name>s)
          RUBY
        end
      end

      class DeserializeCustomType < HasVarnameAndSubtype
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            %<subtype>s.deserialize(%<name>s)
          RUBY
        end
      end

      class DynamicDeepClone < HasVarname
        sig {override.returns(String).checked(:never)}
        def self.format_string
          'T::Props::Utils.deep_clone_object(%<name>s)'
        end
      end

      class Map < HasVarnameAndInner
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.map {|v| %<inner>s}'
        end
      end

      class MapSet < HasVarnameAndInner
        sig {override.returns(String).checked(:never)}
        def self.format_string
          'Set.new(%<name>s) {|v| %<inner>s}'
        end
      end

      class TransformValues < HasVarnameAndInner
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.transform_values {|v| %<inner>s}'
        end
      end

      class TransformKeys < HasVarnameAndInner
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.transform_keys {|k| %<inner>s}'
        end
      end

      class TransformKeyValues < RubyGen::Template
        sig {params(name: TrustedRuby, keys: TrustedRuby, values: TrustedRuby).returns(TrustedRuby).checked(:never)}
        def self.generate(name, keys:, values:)
          new(name: name, keys: keys, values: values).generate
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.each_with_object({}) {|(k,v),h| h[%<keys>s] = %<values>s}'
        end
      end

      class IfNotNil < HasVarnameAndInner
        sig {override.returns(String).checked(:never)}
        def self.format_string
          '%<name>s.nil? ? nil : %<inner>s'
        end
      end

      sig {params(type: T.any(T::Types::Base, Module)).returns(TrustedRuby).checked(:never)}
      def self.generate(type)
        for_type_and_var(type, INPUT_VARNAME)
      end

      sig do
        params(
          type: T.any(T::Types::Base, Module),
          varname: TrustedRuby,
        )
        .returns(TrustedRuby)
        .checked(:never)
      end
      private_class_method def self.for_type_and_var(type, varname)
        case type
        when T::Types::TypedArray
          inner = for_type_and_var(type.type, VALUE_VARNAME)
          if inner == VALUE_VARNAME
            Dup.generate(varname)
          else
            Map.generate(varname, inner)
          end
        when T::Types::TypedSet
          inner = for_type_and_var(type.type, VALUE_VARNAME)
          if inner == VALUE_VARNAME
            Dup.generate(varname)
          else
            MapSet.generate(varname, inner)
          end
        when T::Types::TypedHash
          keys = for_type_and_var(type.keys, KEY_VARNAME)
          values = for_type_and_var(type.values, VALUE_VARNAME)
          if keys == KEY_VARNAME && values == VALUE_VARNAME
            Dup.generate(varname)
          elsif keys == KEY_VARNAME
            TransformValues.generate(varname, values)
          elsif values == VALUE_VARNAME
            TransformKeys.generate(varname, keys)
          else
            TransformKeyValues.generate(varname, keys: keys, values: values)
          end
        when T::Types::Simple
          raw = type.raw_type
          if [TrueClass, FalseClass, NilClass, Symbol, String, Integer, Float].any? {|cls| raw <= cls}
            varname
          elsif raw < T::Props::Serializable
            DeserializeProps.generate(varname, raw)
          elsif raw.singleton_class < T::Props::CustomType
            DeserializeCustomType.generate(varname, T.unsafe(raw))
          else
            DynamicDeepClone.generate(varname)
          end
        when T::Types::Union
          non_nil_type = T::Utils.unwrap_nilable(type)
          if non_nil_type
            inner = for_type_and_var(non_nil_type, varname)
            if varname != INPUT_VARNAME
              IfNotNil.generate(varname, inner)
            else
              # No need to check for nil at top level because that's done by caller
              inner
            end
          else
            DynamicDeepClone.generate(varname)
          end
        else
          if type.singleton_class < T::Props::CustomType
            # Sometimes this comes wrapped in a T::Types::Simple and sometimes not
            DeserializeCustomType.generate(varname, T.unsafe(type))
          else
            DynamicDeepClone.generate(varname)
          end
        end
      end
    end
  end
end
