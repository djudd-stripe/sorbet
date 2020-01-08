# frozen_string_literal: true
# typed: false

module T::Props::Optional
  include T::Props::Plugin
end


##############################################


# NB: This must stay in the same file where T::Props::Optional is defined due to
# T::Props::Decorator#apply_plugin; see https://git.corp.stripe.com/stripe-internal/pay-server/blob/fc7f15593b49875f2d0499ffecfd19798bac05b3/chalk/odm/lib/chalk-odm/document_decorator.rb#L716-L717
module T::Props::Optional::DecoratorMethods
  extend T::Sig

  # TODO: clean this up. This set of options is confusing, and some of them are not universally
  # applicable (e.g., :on_load only applies when using T::Serializable).
  VALID_OPTIONAL_RULES = Set[
    :existing, # deprecated
    :on_load,
    false,
    true,
  ].freeze

  VALID_RULE_KEYS = Set[
    :default,
    :factory,
    :optional,
  ].freeze
  private_constant :VALID_RULE_KEYS

  def valid_rule_key?(key)
    super || VALID_RULE_KEYS.include?(key)
  end

  def prop_optional?(prop); prop_rules(prop)[:fully_optional]; end

  def mutate_prop_backdoor!(prop, key, value)
    rules = props.fetch(prop)
    rules = rules.merge(key => value)
    compute_derived_rules(rules)
    @props = props.merge(prop => rules.freeze).freeze
  end

  def compute_derived_rules(rules)
    rules[:fully_optional] = !T::Props::Utils.need_nil_write_check?(rules)
    rules[:need_nil_read_check] = T::Props::Utils.need_nil_read_check?(rules)
  end

  # checked(:never) - O(runtime object construction)
  sig {returns(T::Hash[Symbol, T::Props::Private::ApplyDefault]).checked(:never)}
  attr_reader :props_with_defaults

  # checked(:never) - O(runtime object construction)
  sig {returns(T::Hash[Symbol, T::Props::Private::SetterFactory::SetterProc]).checked(:never)}
  attr_reader :props_without_defaults

  def add_prop_definition(prop, rules)
    compute_derived_rules(rules)

    default_setter = T::Props::Private::ApplyDefault.for(decorated_class, rules)
    if default_setter
      @props_with_defaults ||= {}
      @props_with_defaults[prop] = default_setter
      @props_without_defaults&.delete(prop) # Handle potential override
    else
      @props_without_defaults ||= {}
      @props_without_defaults[prop] = rules.fetch(:setter_proc)
      @props_with_defaults&.delete(prop) # Handle potential override
    end

    super
  end

  def prop_validate_definition!(name, cls, rules, type)
    result = super

    if (rules_optional = rules[:optional])
      if !VALID_OPTIONAL_RULES.include?(rules_optional)
        raise ArgumentError.new(":optional must be one of #{VALID_OPTIONAL_RULES.inspect}")
      end
    end

    if rules.key?(:default) && rules.key?(:factory)
      raise ArgumentError.new("Setting both :default and :factory is invalid. See: go/chalk-docs")
    end

    result
  end

  # Deprecated, kept for backwards compatibility; use `props_with_defaults&.include?(prop)`
  def has_default?(rules)
    rules.include?(:default) || rules.include?(:factory)
  end

  # Deprecated, kept for backwards compatibility; use `props_with_defaults&.fetch(prop)&.default`
  def get_default(rules, instance_class)
    if rules.include?(:default)
      default = rules.fetch(:default)
      T::Props::Utils.deep_clone_object(default)
    elsif rules.include?(:factory)
      # Factory should never be nil if the key is specified, but
      # we do this rather than 'elsif rules[:factory]' for
      # consistency with :default.
      factory = rules.fetch(:factory)
      instance_class.class_exec(&factory)
    else
      nil
    end
  end
end
