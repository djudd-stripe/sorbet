# frozen_string_literal: true
# typed: strict

module T::Props
  module Private

    # Simple framework for generating Ruby source code from semi-trusted input
    # like user-specified prop names; the intent is that it should be hard to
    # accidentally allow arbitrary code generation while using this framework,
    # at the expense of some verbosity. More specifically, we limit the ways
    # to construct a TrustedRuby instance such that any instance should be
    # built from sanitized input combined in a planned way.
    #
    # We could get arguably stronger guarantees by using something like the
    # `unparser` gem, but that is, unfortunately, very slow as of writing,
    # and anyway also relies on, e.g., `inspect` doing safe escaping for Symbols:
    # https://github.com/mbj/unparser/blob/6d21163c2af2993d36ef01ec8f3fa924f09e93f4/lib/unparser/emitter/literal/primitive.rb#L26
    module RubyGen

      class TrustedRuby
        extend T::Sig
        extend T::Helpers
        sealed!

        sig {params(src: String).void.checked(:never)}
        def initialize(src)
          @src = T.let(src, String)
        end

        sig {override.returns(String).checked(:never)}
        def to_s
          @src
        end

        sig {params(srcs: T::Array[TrustedRuby]).returns(TrustedRuby)}
        def self.join(srcs)
          new(srcs.map(&:to_s).join(';'))
        end

        # This should only be called with statically defined strings,
        # not with anything generated at runtime. TODO: Check this with
        # Rubocop.
        sig {params(src: String).returns(TrustedRuby)}
        def self.constant(src)
          if !src.frozen?
            raise ArgumentError.new("Expected frozen constant input")
          else
            new(src)
          end
        end

        sig {params(template: Template).returns(TrustedRuby)}
        def self.eval_template(template)
          new(Kernel.format(template.class.format_string, template.vars))
        end

        # Only construct using methods above
        private_class_method :new
      end

      class TemplateVar
        extend T::Sig
        extend T::Helpers
        abstract!
        sealed!
      end

      class SymbolLiteral < TemplateVar
        sig {params(sym: Symbol).void.checked(:never)}
        def initialize(sym)
          @sym = T.let(sym, Symbol)
        end

        INSPECT = T.let(Symbol.instance_method(:inspect).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          INSPECT.bind(@sym).call
        end
      end

      class StringLiteral < TemplateVar
        sig {params(str: String).void.checked(:never)}
        def initialize(str)
          @str = T.let(str.freeze, String)
        end

        INSPECT = T.let(String.instance_method(:inspect).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          INSPECT.bind(@str).call
        end
      end

      class IntegerLiteral < TemplateVar
        sig {params(i: Integer).void.checked(:never)}
        def initialize(i)
          @i = T.let(i, Integer)
        end

        TO_S = T.let(Integer.instance_method(:to_s).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          TO_S.bind(@i).call
        end
      end

      class FloatLiteral < TemplateVar
        sig {params(f: Float).void.checked(:never)}
        def initialize(f)
          @f = T.let(f, Float)
        end

        TO_S = T.let(Float.instance_method(:to_s).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          TO_S.bind(@f).call
        end
      end

      class InstanceVar < TemplateVar
        sig {params(name: Symbol).void.checked(:never)}
        def initialize(name)
          if !name.match?(/\A@[a-zA-Z0-9_]+\z/)
            raise ArgumentError.new("Invalid instance variable name: #{name}")
          end
          @name = T.let(name, Symbol)
        end

        TO_S = T.let(Symbol.instance_method(:to_s).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          TO_S.bind(@name).call
        end
      end

      class ModuleLiteral < TemplateVar
        sig {params(cls: Module).void.checked(:never)}
        def initialize(cls)
          @cls = T.let(cls, Module)
        end

        NAME = T.let(Module.instance_method(:name).freeze, UnboundMethod)

        sig {override.returns(String).checked(:never)}
        def to_s
          '::' + NAME.bind(@cls).call
        end
      end

      # Abstract template. Subclasses should define a static format_string
      # which uses named parameters corresponding to the named keyword
      # arguments to `initialize`.
      class Template
        extend T::Sig
        extend T::Helpers
        abstract!

        sig(:final) {returns(T::Hash[Symbol, T.any(TemplateVar, TrustedRuby)])}
        attr_reader :vars

        sig {abstract.returns(String)}
        def self.format_string; end

        sig {params(vars: T::Hash[Symbol, T.any(TemplateVar, TrustedRuby)]).void.checked(:never)}
        def initialize(vars)
          @vars = T.let(vars.freeze, T::Hash[Symbol, T.any(TemplateVar, TrustedRuby)])
        end

        sig(:final) {returns(TrustedRuby).checked(:never)}
        def generate
          TrustedRuby.eval_template(self)
        end

        # Inheritors should provide factory methods with more specific params
        private_class_method :new
      end
    end
  end
end
