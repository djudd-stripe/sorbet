# frozen_string_literal: true
# typed: true

module T::Props
  module Private

    # Generates a specialized `deserialize` implementation for a subclass of
    # T::Props::Serializable, using the facilities in `RubyGen`.
    #
    # The basic idea is that we analyze the props and for each prop, generate
    # the simplest possible logic as a block of Ruby source, so that we don't
    # pay the cost of supporting types like T:::Hash[CustomType, SubstructType]
    # when deserializing a simple Integer. Then we join those together,
    # with a little shared logic to be able to detect when we get input keys
    # that don't match any prop.
    #
    # Each instance of this class is responsible for generating the Ruby source
    # for a single prop; there's a class method which takes a hash of props
    # and generates the full `deserialize` implementation.
    class DeserializerGenerator
      extend T::Sig

      TrustedRuby = RubyGen::TrustedRuby

      class DeserializeMethod < RubyGen::Template
        sig {params(name: TrustedRuby, parts: T::Array[PropDeserializationLogic]).returns(DeserializeMethod)}
        def self.from_parts(name, parts)
          new(
            name: name,
            prop_count: RubyGen::IntegerLiteral.new(parts.size),
            body: TrustedRuby.join(parts.map(&:generate)),
          )
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            def %<name>s(hash)
              found = %<prop_count>s
              %<body>s
              found
            end
          RUBY
        end
      end

      class PropDeserializationLogic < RubyGen::Template
        sig do
          params(
            serialized_form: String,
            accessor_key: Symbol,
            nil_handler: T.any(TrustedRuby, RubyGen::TemplateVar),
            parser: T.any(TrustedRuby, RubyGen::TemplateVar),
          )
          .returns(PropDeserializationLogic)
        end
        def self.from(serialized_form:, accessor_key:, nil_handler:, parser:)
          new(
            serialized_form: RubyGen::StringLiteral.new(serialized_form),
            accessor_key: RubyGen::InstanceVar.new(accessor_key),
            nil_handler: nil_handler,
            parser: parser,
          )
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            val = hash[%<serialized_form>s]
            %<accessor_key>s = if val.nil?
              found -= 1 unless hash.key?(%<serialized_form>s)
              %<nil_handler>s
            else
              %<parser>s
            end
          RUBY
        end
      end

      class RecursiveDeserialize < RubyGen::Template
        abstract!

        sig {params(subtype: Module).returns(RecursiveDeserialize)}
        def self.from_subtype(subtype)
          new(
            subtype: RubyGen::ModuleLiteral.new(subtype),
            method_name: DeserMethod.from_subtype(subtype),
          )
        end
      end

      class DeserProp < RecursiveDeserialize
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            %<subtype>s.%<method_name>s(val)
          RUBY
        end
      end

      class MapProp < RecursiveDeserialize
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            val.map {|v| v && %<subtype>s.%<method_name>s(v)}
          RUBY
        end
      end

      class TransformPropKeys < RecursiveDeserialize
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            val.each_with_object({}) do |(k,v), h|
              h[%<subtype>s.%<method_name>s(k)] = v
            end
          RUBY
        end
      end

      class TransformPropValues < RecursiveDeserialize
        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            val.transform_values {|v| v && %<subtype>s.%<method_name>s(v)}
          RUBY
        end
      end

      class TransformPropKeysAndValues < RubyGen::Template
        sig do
          params(
            keys: Module,
            values: Module,
          )
          .returns(TransformPropKeysAndValues)
        end
        def self.from(keys:, values:)
          new(
            key_subtype: RubyGen::ModuleLiteral.new(keys),
            key_method: DeserMethod.from_subtype(keys),
            val_subtype: RubyGen::ModuleLiteral.new(values),
            val_method: DeserMethod.from_subtype(values),
          )
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            val.each_with_object({}) do |(k,v), h|
              h[%<key_subtype>s.%<key_method>s(k)] = v && %<val_subtype>s.%<val_method>s(v)
            end
          RUBY
        end
      end

      class RaiseOnNil < RubyGen::Template
        sig {params(serialized_form: String).returns(RaiseOnNil)}
        def self.from_serialized_form(serialized_form)
          new(serialized_form: RubyGen::StringLiteral.new(serialized_form))
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            self.class.decorator.raise_nil_deserialize_error(%<serialized_form>s)
          RUBY
        end
      end

      class StoreOnNil < RubyGen::Template
        sig {params(prop: Symbol).returns(StoreOnNil)}
        def self.from_prop(prop)
          new(prop: RubyGen::SymbolLiteral.new(prop))
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            self.required_prop_missing_from_deserialize(%<prop>s)
            nil
          RUBY
        end
      end

      class CallFactory < RubyGen::Template
        sig {params(prop: Symbol, method_name: TrustedRuby).returns(CallFactory)}
        def self.from_prop(prop, method_name:)
          new(prop: RubyGen::SymbolLiteral.new(prop), method_name: method_name)
        end

        sig {override.returns(String).checked(:never)}
        def self.format_string
          <<~RUBY
            decorator = self.class.decorator
            decorator.%<method_name>s(decorator.props[%<prop>s], self.class)
          RUBY
        end
      end

      # Generate a method that takes a T::Hash[String, T.untyped] representing
      # serialized props, sets instance variables for each prop found in the
      # input, and returns the count of we props set (which we can use to check
      # for unexpected input keys with minimal effect on the fast path).
      sig do
        params(
          name: TrustedRuby,
          props: T::Hash[Symbol, T::Hash[Symbol, T.untyped]]
        )
        .returns(TrustedRuby)
        .checked(:never)
      end
      def self.generate_deserializer(name, props)
        parts = props.flat_map do |prop, rules|
          new(prop, rules).generate_prop_deserialization_logic
        end
        DeserializeMethod.from_parts(name, parts).generate
      end

      private_class_method :new

      sig {params(prop: Symbol, rules: T::Hash[Symbol, T.untyped]).void.checked(:never)}
      def initialize(prop, rules)
        @prop = prop
        @rules = rules
      end

      sig {returns(PropDeserializationLogic).checked(:never)}
      def generate_prop_deserialization_logic
        PropDeserializationLogic.from(
          accessor_key: @rules.fetch(:accessor_key),
          serialized_form: @rules.fetch(:serialized_form),
          parser: generate_parser,
          nil_handler: generate_nil_handler,
        )
      end

      module Clone
        SHALLOW = TrustedRuby.constant('val.dup')
        DEEP = TrustedRuby.constant('T::Props::Utils.deep_clone_object(val)')
        NONE = TrustedRuby.constant('val')
      end

      sig {returns(T.any(TrustedRuby, RubyGen::TemplateVar)).checked(:never)}
      private def generate_parser
        subtype = @rules[:serializable_subtype]
        subtype ||= @rules.fetch(:type) if @rules[:type_is_custom_type]
        if subtype
          if @rules[:type_is_array_of_serializable]
            MapProp.from_subtype(subtype).generate
          elsif @rules[:type_is_hash_of_custom_type_keys]
            if @rules[:type_is_hash_of_serializable_values]
              TransformPropKeysAndValues.from(
                keys: subtype.fetch(:keys),
                values: subtype.fetch(:values),
              ).generate
            else
              TransformPropKeys.from_subtype(subtype).generate
            end
          elsif @rules[:type_is_hash_of_serializable_values]
            TransformPropValues.from_subtype(subtype).generate
          else
            DeserProp.from_subtype(subtype).generate
          end
        elsif (needs_clone = @rules[:type_needs_clone])
          if needs_clone == :shallow
            Clone::SHALLOW
          else
            Clone::DEEP
          end
        else
          Clone::NONE
        end
      end

      module DeserMethod
        extend T::Sig

        DESERIALIZE = TrustedRuby.constant('deserialize')
        FROM_HASH = TrustedRuby.constant('from_hash')

        sig do
          params(
            subtype: Module
          )
          .returns(TrustedRuby)
          .checked(:never)
        end
        def self.from_subtype(subtype)
          case subtype
          when T::Props::CustomType
            DeserMethod::DESERIALIZE
          else
            DeserMethod::FROM_HASH
          end
        end
      end

      module Empty
        HASH = {}.freeze
        ARRAY = [].freeze
      end

      module Default
        TRUE = TrustedRuby.constant('true')
        FALSE = TrustedRuby.constant('false')
        NIL = TrustedRuby.constant('nil')
        EMPTY_ARRAY = TrustedRuby.constant('[]')
        EMPTY_HASH = TrustedRuby.constant('{}')
      end

      module DefaultMethod
        FIXED = TrustedRuby.constant('get_fixed_default')
        FACTORY = TrustedRuby.constant('get_factory_default')
      end

      sig {returns(T.any(TrustedRuby, RubyGen::TemplateVar)).checked(:never)}
      private def generate_nil_handler
        if T::Props::Utils.required_prop?(@rules)
          if @rules.key?(:default)
            default = @rules[:default]
            case default
            when Integer
              RubyGen::IntegerLiteral.new(default)
            when Float
              RubyGen::FloatLiteral.new(default)
            when TrueClass
              Default::TRUE
            when FalseClass
              Default::FALSE
            when String
              RubyGen::StringLiteral.new(default)
            when Symbol
              RubyGen::SymbolLiteral.new(default)
            when NilClass
              Default::NIL
            when Empty::HASH
              Default::EMPTY_HASH
            when Empty::ARRAY
              Default::EMPTY_ARRAY
            else
              CallFactory.from_prop(@prop, method_name: DefaultMethod::FIXED).generate
            end
          elsif @rules.key?(:factory)
            CallFactory.from_prop(@prop, method_name: DefaultMethod::FACTORY).generate
          else
            RaiseOnNil.from_serialized_form(@rules.fetch(:serialized_form)).generate
          end
        elsif @rules[:need_nil_read_check]
          StoreOnNil.from_prop(@prop).generate
        else
          Default::NIL
        end
      end
    end
  end
end
