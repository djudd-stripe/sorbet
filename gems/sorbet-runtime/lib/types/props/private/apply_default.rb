# frozen_string_literal: true
# typed: true

module T::Props
  module Private
    class ApplyDefault
      extend T::Sig
      extend T::Helpers
      abstract!

      # checked(:never) - O(object construction x prop count)
      sig {returns(SetterFactory::SetterProc).checked(:never)}
      attr_reader :setter_proc

      sig {params(accessor_key: Symbol, setter_proc: SetterFactory::SetterProc).void}
      def initialize(accessor_key, setter_proc)
        @accessor_key = accessor_key
        @setter_proc = setter_proc
      end

      # checked(:never) - O(object construction x prop count)
      sig {abstract.returns(T.untyped).checked(:never)}
      def default; end

      # checked(:never) - O(object construction x prop count)
      sig {abstract.params(instance: T.all(T::Props::Optional, Object)).void.checked(:never)}
      def set_default(instance); end

      NO_CLONE_TYPES = [TrueClass, FalseClass, NilClass, Symbol, Numeric, T::Enum].freeze

      # checked(:never) - Rules hash is expensive to check
      sig {params(cls: Module, rules: T::Hash[Symbol, T.untyped]).returns(T.nilable(ApplyDefault)).checked(:never)}
      def self.for(cls, rules)
        accessor_key = rules.fetch(:accessor_key)
        setter = rules.fetch(:setter_proc)

        if rules.key?(:factory)
          ApplyDefaultFactory.new(cls, rules.fetch(:factory), accessor_key, setter)
        elsif rules.key?(:default)
          default = rules.fetch(:default)
          case default
          when *NO_CLONE_TYPES
            return ApplyPrimitiveDefault.new(default, accessor_key, setter)
          when String
            if default.frozen?
              return ApplyPrimitiveDefault.new(default, accessor_key, setter)
            end
          when Array
            if default.empty? && default.class == Array
              return ApplyEmptyArrayDefault.new(accessor_key, setter)
            end
          when Hash
            if default.empty? && default.default.nil? && T.unsafe(default).default_proc.nil? && default.class == Hash
              return ApplyEmptyHashDefault.new(accessor_key, setter)
            end
          end

          ApplyComplexDefault.new(default, accessor_key, setter)
        else
          nil
        end
      end
    end

    class ApplyFixedDefault < ApplyDefault
      abstract!

      sig {params(default: T.untyped, accessor_key: Symbol, setter_proc: SetterFactory::SetterProc).void}
      def initialize(default, accessor_key, setter_proc)
        # FIXME: Ideally we'd check here that the default is actually a valid
        # value for this field, but existing code relies on the fact that we don't.
        #
        # :(
        #
        # setter_proc.call(default)
        @default = default
        super(accessor_key, setter_proc)
      end

      # checked(:never) - O(object construction x prop count)
      sig {override.params(instance: T.all(T::Props::Optional, Object)).void.checked(:never)}
      def set_default(instance)
        instance.instance_variable_set(@accessor_key, default)
      end
    end

    class ApplyPrimitiveDefault < ApplyFixedDefault
      # checked(:never) - O(object construction x prop count)
      sig {override.returns(T.untyped).checked(:never)}
      attr_reader :default
    end

    class ApplyComplexDefault < ApplyFixedDefault
      # checked(:never) - O(object construction x prop count)
      sig {override.returns(T.untyped).checked(:never)}
      def default
        T::Props::Utils.deep_clone_object(@default)
      end
    end

    # Special case since it's so common
    class ApplyEmptyArrayDefault < ApplyDefault
      # checked(:never) - O(object construction x prop count)
      sig {override.params(instance: T.all(T::Props::Optional, Object)).void.checked(:never)}
      def set_default(instance)
        instance.instance_variable_set(@accessor_key, [])
      end

      # checked(:never) - O(object construction x prop count)
      sig {override.returns(Array).checked(:never)}
      def default
        []
      end
    end

    # Special case since it's so common
    class ApplyEmptyHashDefault < ApplyDefault
      # checked(:never) - O(object construction x prop count)
      sig {override.params(instance: T.all(T::Props::Optional, Object)).void.checked(:never)}
      def set_default(instance)
        instance.instance_variable_set(@accessor_key, {})
      end

      # checked(:never) - O(object construction x prop count)
      sig {override.returns(Hash).checked(:never)}
      def default
        {}
      end
    end

    class ApplyDefaultFactory < ApplyDefault
      sig {params(cls: Module, factory: T.proc.returns(T.untyped), accessor_key: Symbol, setter_proc: SetterFactory::SetterProc).void}
      def initialize(cls, factory, accessor_key, setter_proc)
        @class = cls
        @factory = factory
        super(accessor_key, setter_proc)
      end

      # checked(:never) - O(object construction x prop count)
      sig {override.params(instance: T.all(T::Props::Optional, Object)).void.checked(:never)}
      def set_default(instance)
        # Use the actual setter to validate the factory returns a legitimate
        # value every time
        instance.instance_exec(default, &@setter_proc)
      end

      # checked(:never) - O(object construction x prop count)
      sig {override.returns(T.untyped).checked(:never)}
      def default
        @class.class_exec(&@factory)
      end
    end
  end
end
