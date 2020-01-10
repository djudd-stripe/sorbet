# frozen_string_literal: true
# typed: strict

module T::Props
  module Private
    module SerdeFactory
      extend T::Sig

      # Note: we have versions with/without the safe navigation operator
      # here because it's easy, but the performance difference is barely
      # detectable even in the simplest case (e.g. `dup` on an empty array),
      # so we don't bother in more complex cases (`map`, `transform_values`, etc).
      NILABLE_DUP = ->(x) {x&.dup}.freeze
      NONNIL_DUP = ->(x) {x.dup}.freeze
      STRICT_SERIALIZE_PROPS = ->(x) {x&.serialize(true)}.freeze
      NONSTRICT_SERIALIZE_PROPS = ->(x) {x&.serialize(false)}.freeze
      DYNAMIC_DEEP_CLONE = T::Props::Utils.method(:deep_clone_object).to_proc.freeze
      NO_TRANSFORM_TYPES = [TrueClass, FalseClass, NilClass, Symbol, String, Numeric].freeze

      class Mode < T::Enum
        enums do
          DESERIALIZE = new
          SERIALIZE_STRICT = new
          SERIALIZE_NONSTRICT = new
        end
      end

      sig do
        params(
          type: T.any(T::Types::Base, Module),
          mode: Mode,
          nilable: T::Boolean,
        )
        .returns(T.nilable(T.proc.params(val: T.untyped).returns(T.untyped)))
        .checked(:never)
      end
      def self.generate(type, mode, nilable)
        case type
        when T::Types::TypedArray
          inner = generate(type.type, mode, false)
          if inner.nil?
            nilable ? NILABLE_DUP : NONNIL_DUP
          else
            nilable ? ->(x) {x&.map(&inner)} : ->(x) {x.map(&inner)}
          end
        when T::Types::TypedSet
          inner = generate(type.type, mode, false)
          if inner.nil?
            nilable ? NILABLE_DUP : NONNIL_DUP
          else
            nilable ? ->(x) {x && Set.new(x, &inner)} : ->(x) {Set.new(x, &inner)}
          end
        when T::Types::TypedHash
          keys = generate(type.keys, mode, false)
          values = generate(type.values, mode, false)
          if keys.nil? && values.nil?
            nilable ? NILABLE_DUP : NONNIL_DUP
          elsif keys.nil?
            nilable ? ->(x) {x&.transform_values(&values)} : ->(x) {x.transform_values(&values)}
          elsif values.nil?
            nilable ? ->(x) {x&.transform_keys(&keys)} : ->(x) {x.transform_keys(&keys)}
          elsif nilable
            ->(x) {x&.each_with_object({}) {|(k,v),h| h[keys.call(k)] = values.call(v)}}
          else
            ->(x) {x.each_with_object({}) {|(k,v),h| h[keys.call(k)] = values.call(v)}}
          end
        when T::Types::Simple
          raw = type.raw_type
          if NO_TRANSFORM_TYPES.any? {|cls| raw <= cls}
            nil
          elsif raw < T::Props::Serializable
            handle_serializable_subtype(raw, mode, nilable)
          elsif raw.singleton_class < T::Props::CustomType
            handle_custom_type(raw, mode, nilable)
          else
            DYNAMIC_DEEP_CLONE
          end
        when T::Types::Union
          non_nil_type = T::Utils.unwrap_nilable(type)
          if non_nil_type
            generate(non_nil_type, mode, true)
          else
            DYNAMIC_DEEP_CLONE
          end
        else
          if type.singleton_class < T::Props::CustomType
            # Sometimes this comes wrapped in a T::Types::Simple and sometimes not
            handle_custom_type(type, mode, nilable)
          else
            DYNAMIC_DEEP_CLONE
          end
        end
      end

      sig do
        params(
          type: Module,
          mode: Mode,
          nilable: T::Boolean,
        )
        .returns(T.proc.params(val: T.untyped).returns(T.untyped))
        .checked(:never)
      end
      private_class_method def self.handle_custom_type(type, mode, nilable)
        case mode
        when Mode::SERIALIZE_STRICT, Mode::SERIALIZE_NONSTRICT
          proc do |val|
            if nilable && val.nil?
              nil
            else
              val = type.send(:serialize, val)
              unless T::Props::CustomType.valid_serialization?(val, type)
                msg = "#{type} did not serialize to a valid scalar type. It became a: #{val.class}"
                if val.is_a?(Hash)
                  msg += "\nIf you want to store a structured Hash, consider using a T::Struct as your type."
                end
                raise T::Props::InvalidValueError.new(msg)
              end
              val
            end
          end
        when Mode::DESERIALIZE
          if nilable
            ->(x) {x.nil? ? nil : type.send(:deserialize, x)}
          else
            type.method(:deserialize).to_proc
          end
        else
          T.absurd
        end
      end

      sig do
        params(
          type: Module,
          mode: Mode,
          nilable: T::Boolean,
        )
        .returns(T.proc.params(val: T.untyped).returns(T.untyped))
        .checked(:never)
      end
      private_class_method def self.handle_serializable_subtype(type, mode, nilable)
        case mode
        when Mode::SERIALIZE_STRICT
          STRICT_SERIALIZE_PROPS
        when Mode::SERIALIZE_NONSTRICT
          NONSTRICT_SERIALIZE_PROPS
        when Mode::DESERIALIZE
          if nilable
            # Use && instead of ternary since we know nil is the only possible falsey value
            ->(x) {x && type.send(:from_hash, x)}
          else
            type.method(:from_hash).to_proc
          end
        else
          T.absurd
        end
      end
    end
  end
end

