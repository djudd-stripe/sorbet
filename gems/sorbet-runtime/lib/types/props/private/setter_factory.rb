# frozen_string_literal: true
# typed: strict

module T::Props
  module Private
    module SetterFactory
      extend T::Sig

      SetterProc = T.type_alias {T.proc.params(val: T.untyped).void}

      sig do
        params(
          klass: T.all(Module, T::Props::ClassMethods),
          prop: Symbol,
          rules: T::Hash[Symbol, T.untyped]
        )
        .returns(SetterProc)
        .checked(:never)
      end
      def self.build_setter_proc(klass, prop, rules)
        # Our nil check works differently than a simple T.nilable for various
        # reasons (including the `raise_on_nil_write` setting, the existence
        # of defaults & factories, and the fact that we allow `T.nilable(Foo)`
        # where Foo < T::Props::CustomType as a prop type even though calling
        # `valid?` on it won't work as expected), so unwrap any T.nilable and
        # do a check manually. (Note this hack does not fix custom types as
        # collection elements.)
        non_nil_type = if rules[:type_is_custom_type]
          rules.fetch(:type)
        else
          T::Utils::Nilable.get_underlying_type_object(rules.fetch(:type_object))
        end
        accessor_key = rules.fetch(:accessor_key)
        raise_error = ->(val) {raise_pretty_error(klass, prop, non_nil_type, val)}

        # It seems like a bug that this affects the behavior of setters, but
        # some existing code relies on this behavior
        has_explicit_nil_default = rules.key?(:default) && rules.fetch(:default).nil?

        if !T::Props::Utils.need_nil_write_check?(rules) || has_explicit_nil_default
          proc do |val|
            if val.nil?
              instance_variable_set(accessor_key, nil)
            elsif non_nil_type.valid?(val)
              instance_variable_set(accessor_key, val)
            else
              raise_error.call(val)
            end
          end
        else
          proc do |val|
            if non_nil_type.valid?(val)
              instance_variable_set(accessor_key, val)
            else
              raise_error.call(val)
            end
          end
        end
      end

      sig do
        params(
          klass: T.all(Module, T::Props::ClassMethods),
          prop: Symbol,
          type: T.any(T::Types::Base, Module),
          val: T.untyped,
        )
        .returns(SetterProc)
      end
      private_class_method def self.raise_pretty_error(klass, prop, type, val)
        base_message = "Can't set #{klass.name}.#{prop} to #{val.inspect} (instance of #{val.class}) - need a #{type}"

        pretty_message = "Parameter '#{prop}': #{base_message}\n"
        caller_loc = caller_locations&.find {|l| !l.to_s.include?('sorbet-runtime/lib/types/props')}
        if caller_loc
          pretty_message += "Caller: #{caller_loc.path}:#{caller_loc.lineno}\n"
        end

        T::Configuration.call_validation_error_handler(
          nil,
          message: base_message,
          pretty_message: pretty_message,
          kind: 'Parameter',
          name: prop,
          type: type,
          value: val,
          location: caller_loc,
        )
      end
    end
  end
end
