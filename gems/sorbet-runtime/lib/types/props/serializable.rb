# frozen_string_literal: true
# typed: false

module T::Props::Serializable
  include T::Props::Plugin
  # Required because we have special handling for `optional: false`
  include T::Props::Optional
  # Required because we have special handling for extra_props
  include T::Props::PrettyPrintable

  # Serializes this object to a hash, suitable for conversion to
  # JSON/BSON.
  #
  # @param strict [T::Boolean] (true) If false, do not raise an
  #   exception if this object has mandatory props with missing
  #   values.
  # @return [Hash] A serialization of this object.
  def serialize(strict=true)
    decorator = self.class.decorator
    h = {}

    decorator.props.each do |prop, rules|
      hkey = rules[:serialized_form]

      val = decorator.get(self, prop, rules)

      if val.nil? && strict && !rules[:fully_optional]
        # If the prop was already missing during deserialization, that means the application
        # code already had to deal with a nil value, which means we wouldn't be accomplishing
        # much by raising here (other than causing an unnecessary breakage).
        if self.required_prop_missing_from_deserialize?(prop)
          T::Configuration.log_info_handler(
            "chalk-odm: missing required property in serialize",
            prop: prop, class: self.class.name, id: decorator.get_id(self)
          )
        else
          raise T::Props::InvalidValueError.new("#{self.class.name}.#{prop} not set for non-optional prop")
        end
      end

      # Don't serialize values that are nil to save space (both the
      # nil value itself and the field name in the serialized BSON
      # document)
      next if rules[:dont_store] || val.nil?

      transform = strict ? rules[:strict_serialize_proc] : rules[:nonstrict_serialize_proc]
      val = transform.call(val) if transform

      h[hkey] = val
    end

    h.merge!(@_extra_props) if @_extra_props

    h
  end

  # Populates the property values on this object with the values
  # from a hash. In general, prefer to use {.from_hash} to construct
  # a new instance, instead of loading into an existing instance.
  #
  # @param hash [Hash<String, Object>] The hash to take property
  #  values from.
  # @param strict [T::Boolean] (false) If true, raise an exception if
  #  the hash contains keys that do not correspond to any known
  #  props on this instance.
  # @return [void]
  def deserialize(hash, strict=false)
    decorator = self.class.decorator

    found_count = decorator.prop_deserializers&.count do |deser|
      deser.call(self, hash)
    end || 0

    # We compute extra_props this way specifically for performance
    if found_count < hash.size
      pbsf = decorator.prop_by_serialized_forms
      h = hash.reject {|k, _| pbsf.key?(k)}

      if strict
        raise "Unknown properties for #{self.class.name}: #{h.keys.inspect}"
      else
        @_extra_props = h
      end
    end
  end

  # with() will clone the old object to the new object and merge the specified props to the new object.
  def with(changed_props)
    with_existing_hash(changed_props, existing_hash: self.serialize)
  end

  private def recursive_stringify_keys(obj)
    if obj.is_a?(Hash)
      new_obj = obj.class.new
      obj.each do |k, v|
        new_obj[k.to_s] = recursive_stringify_keys(v)
      end
    elsif obj.is_a?(Array)
      new_obj = obj.map {|v| recursive_stringify_keys(v)}
    else
      new_obj = obj
    end
    new_obj
  end

  private def with_existing_hash(changed_props, existing_hash:)
    serialized = existing_hash
    new_val = self.class.from_hash(serialized.merge(recursive_stringify_keys(changed_props)))
    old_extra = self.instance_variable_get(:@_extra_props) # rubocop:disable PrisonGuard/NoLurkyInstanceVariableAccess
    new_extra = new_val.instance_variable_get(:@_extra_props) # rubocop:disable PrisonGuard/NoLurkyInstanceVariableAccess
    if old_extra != new_extra
      difference =
        if old_extra
          new_extra.reject {|k, v| old_extra[k] == v}
        else
          new_extra
        end
      raise ArgumentError.new("Unexpected arguments: input(#{changed_props}), unexpected(#{difference})")
    end
    new_val
  end

  # @return [T::Boolean] Was this property missing during deserialize?
  def required_prop_missing_from_deserialize?(prop)
    return false if @_required_props_missing_from_deserialize.nil?
    @_required_props_missing_from_deserialize.include?(prop)
  end

  # @return Marks this property as missing during deserialize
  def required_prop_missing_from_deserialize(prop)
    @_required_props_missing_from_deserialize ||= Set[]
    @_required_props_missing_from_deserialize << prop
    nil
  end
end


##############################################

# NB: This must stay in the same file where T::Props::Serializable is defined due to
# T::Props::Decorator#apply_plugin; see https://git.corp.stripe.com/stripe-internal/pay-server/blob/fc7f15593b49875f2d0499ffecfd19798bac05b3/chalk/odm/lib/chalk-odm/document_decorator.rb#L716-L717
module T::Props::Serializable::DecoratorMethods

  VALID_RULE_KEYS = Set[:dont_store, :name, :raise_on_nil_write].freeze
  private_constant :VALID_RULE_KEYS

  def valid_rule_key?(key)
    super || VALID_RULE_KEYS.include?(key)
  end

  def required_props
    @class.props.select {|_, v| T::Props::Utils.required_prop?(v)}.keys
  end

  def prop_dont_store?(prop); prop_rules(prop)[:dont_store]; end
  def prop_by_serialized_forms; @class.prop_by_serialized_forms; end

  def from_hash(hash, strict=false)
    raise ArgumentError.new("#{hash.inspect} provided to from_hash") if !(hash && hash.is_a?(Hash))

    i = @class.allocate
    i.deserialize(hash, strict)

    i
  end

  def prop_serialized_form(prop)
    prop_rules(prop)[:serialized_form]
  end

  def serialized_form_prop(serialized_form)
    prop_by_serialized_forms[serialized_form.to_s] || raise("No such serialized form: #{serialized_form.inspect}")
  end

  attr_reader :prop_deserializers

  def add_prop_definition(prop, rules)
    rules[:serialized_form] = rules.fetch(:name, prop.to_s)

    type_object = rules.fetch(:type_object)
    if (p = T::Props::Private::SerdeFactory.generate(type_object, T::Props::Private::SerdeFactory::Mode::SERIALIZE_STRICT, false))
      rules[:strict_serialize_proc] = p
    end
    if (p = T::Props::Private::SerdeFactory.generate(type_object, T::Props::Private::SerdeFactory::Mode::SERIALIZE_NONSTRICT, false))
      rules[:nonstrict_serialize_proc] = p
    end

    res = super
    prop_by_serialized_forms[rules[:serialized_form]] = prop
    @prop_deserializers ||= []
    @prop_deserializers << make_deserialize_proc(prop, rules)
    res
  end

  private def make_deserialize_proc(prop, rules)
    hkey = rules.fetch(:serialized_form)
    accessor_key = rules.fetch(:accessor_key)
    transformer = T::Props::Private::SerdeFactory.generate(
      rules.fetch(:type_object),
      T::Props::Private::SerdeFactory::Mode::DESERIALIZE,
      false,
    )

    if T::Props::Utils.required_prop?(rules) && (default_setter = props_with_defaults&.fetch(prop, nil))
      if transformer.nil?
        proc do |instance, hash|
          val = hash[hkey]
          found = if val.nil?
            val = default_setter.default
            hash.key?(hkey)
          else
            true
          end
          instance.instance_variable_set(accessor_key, val)
          found
        end
      elsif transformer == T::Props::Private::SerdeFactory::NONNIL_DUP
        proc do |instance, hash|
          val = hash[hkey]
          found = if val.nil?
            val = default_setter.default
            hash.key?(hkey)
          else
            val = val.dup
            true
          end
          instance.instance_variable_set(accessor_key, val)
          found
        end
      else
        proc do |instance, hash|
          val = hash[hkey]
          found = if val.nil?
            val = default_setter.default
            hash.key?(hkey)
          else
            val = transformer.call(val)
            true
          end
          instance.instance_variable_set(accessor_key, val)
          found
        end
      end
    elsif T::Props::Utils.required_prop?(rules)
      if transformer.nil?
        proc do |instance, hash|
          val = hash[hkey]
          instance.class.decorator.raise_nil_deserialize_error(hkey) if val.nil?
          instance.instance_variable_set(accessor_key, val)
          true
        end
      elsif transformer == T::Props::Private::SerdeFactory::NONNIL_DUP
        proc do |instance, hash|
          val = hash[hkey]
          instance.class.decorator.raise_nil_deserialize_error(hkey) if val.nil?
          instance.instance_variable_set(accessor_key, val.dup)
          true
        end
      else
        proc do |instance, hash|
          val = hash[hkey]
          instance.class.decorator.raise_nil_deserialize_error(hkey) if val.nil?
          instance.instance_variable_set(accessor_key, transformer.call(val))
          true
        end
      end
    elsif rules[:need_nil_read_check]
      if transformer.nil?
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            instance.send(:required_prop_missing_from_deserialize, prop)
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, val)
            true
          end
        end
      elsif transformer == T::Props::Private::SerdeFactory::NONNIL_DUP
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            instance.send(:required_prop_missing_from_deserialize, prop)
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, val.dup)
            true
          end
        end
      else
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            instance.send(:required_prop_missing_from_deserialize, prop)
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, transformer.call(val))
            true
          end
        end
      end
    else
      if transformer.nil?
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, val)
            true
          end
        end
      elsif transformer == T::Props::Private::SerdeFactory::NONNIL_DUP
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, val.dup)
            true
          end
        end
      else
        proc do |instance, hash|
          val = hash[hkey]
          if val.nil?
            hash.key?(hkey)
          else
            instance.instance_variable_set(accessor_key, transformer.call(val))
            true
          end
        end
      end
    end
  end

  def raise_nil_deserialize_error(hkey)
    msg = "Tried to deserialize a required prop from a nil value. It's "\
      "possible that a nil value exists in the database, so you should "\
      "provide a `default: or factory:` for this prop (see go/optional "\
      "for more details). If this is already the case, you probably "\
      "omitted a required prop from the `fields:` option when doing a "\
      "partial load."
    storytime = {prop: hkey, klass: decorated_class.name}

    # Notify the model owner if it exists, and always notify the API owner.
    begin
      if defined?(Opus) && defined?(Opus::Ownership) && decorated_class < Opus::Ownership
        T::Configuration.hard_assert_handler(
          msg,
          storytime: storytime,
          project: decorated_class.get_owner
        )
      end
    ensure
      T::Configuration.hard_assert_handler(msg, storytime: storytime)
    end
  end

  def prop_validate_definition!(name, cls, rules, type)
    result = super

    if (rules_name = rules[:name])
      unless rules_name.is_a?(String)
        raise ArgumentError.new("Invalid name in prop #{@class.name}.#{name}: #{rules_name.inspect}")
      end

      validate_prop_name(rules_name)
    end

    if !rules[:raise_on_nil_write].nil? && rules[:raise_on_nil_write] != true
        raise ArgumentError.new("The value of `raise_on_nil_write` if specified must be `true` (given: #{rules[:raise_on_nil_write]}).")
    end

    result
  end

  def get_id(instance)
    prop = prop_by_serialized_forms['_id']
    if prop
      get(instance, prop)
    else
      nil
    end
  end

  EMPTY_EXTRA_PROPS = {}.freeze
  private_constant :EMPTY_EXTRA_PROPS

  def extra_props(instance)
    instance.instance_variable_get(:@_extra_props) || EMPTY_EXTRA_PROPS
  end

  # @override T::Props::PrettyPrintable
  private def inspect_instance_components(instance, multiline:, indent:)
    if (extra_props = extra_props(instance)) && !extra_props.empty?
      pretty_kvs = extra_props.map {|k, v| [k.to_sym, v.inspect]}
      extra = join_props_with_pretty_values(pretty_kvs, multiline: false)
      super + ["@_extra_props=<#{extra}>"]
    else
      super
    end
  end
end


##############################################


# NB: This must stay in the same file where T::Props::Serializable is defined due to
# T::Props::Decorator#apply_plugin; see https://git.corp.stripe.com/stripe-internal/pay-server/blob/fc7f15593b49875f2d0499ffecfd19798bac05b3/chalk/odm/lib/chalk-odm/document_decorator.rb#L716-L717
module T::Props::Serializable::ClassMethods
  def prop_by_serialized_forms; @prop_by_serialized_forms ||= {}; end

  # @!method self.from_hash(hash, strict)
  #
  # Allocate a new instance and call {#deserialize} to load a new
  # object from a hash.
  # @return [Serializable]
  def from_hash(hash, strict=false)
    self.decorator.from_hash(hash, strict)
  end

  # Equivalent to {.from_hash} with `strict` set to true.
  # @return [Serializable]
  def from_hash!(hash)
    self.decorator.from_hash(hash, true)
  end
end
