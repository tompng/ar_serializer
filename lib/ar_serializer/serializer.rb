require 'ar_serializer/error'

class ArSerializer::CustomSerializable
  attr_reader :ar_custom_serializable_models
  def initialize(models, &block)
    @ar_custom_serializable_models = models
    @block = block
  end

  def ar_custom_serializable_data(result)
    @block.call result
  end
end

module ArSerializer::ArrayLikeSerializable
end

module ArSerializer::Serializer
  def self.current_namespaces
    Thread.current[:ar_serializer_current_namespaces] || [nil]
  end

  def self.with_namespaces(namespaces)
    namespaces_was = Thread.current[:ar_serializer_current_namespaces]
    Thread.current[:ar_serializer_current_namespaces] = Array(namespaces) | [nil]
    yield
  ensure
    Thread.current[:ar_serializer_current_namespaces] = namespaces_was
  end

  def self.serialize(model, query, context: nil, use: nil, permission: true)
    return nil if model.nil?
    with_namespaces use do
      attributes = parse_args(query)[:attributes]
      if model.is_a?(ArSerializer::Serializable)
        result = _serialize [model], attributes, context, permission: permission
        result[model]
      else
        models = model.to_a
        result = _serialize models, attributes, context, permission: permission
        models.map { |m| result[m] }.compact
      end
    end
  end

  def self._serialize(mixed_models, attributes, context, only: nil, except: nil, permission: true)
    output_for_model = {}
    mixed_models.group_by(&:class).each do |klass, models|
      next unless klass.respond_to? :_serializer_field_info
      models.uniq!
      if attributes.any? { |k, _| k == :* }
        all_keys = klass._serializer_field_keys.map(&:to_sym)
        all_keys &= only.map(&:to_sym) if only
        all_keys -= except.map(&:to_sym) if except
        attributes = all_keys.map { |k| [k, {}] } + attributes.reject { |k, _| k == :* }
      end
      attributes.each do |name, sub_args|
        field_name = sub_args[:field_name] || name
        field = klass._serializer_field_info field_name
        if field.nil? || field.private?
          message = "No serializer field `#{field_name}`#{" namespaces: #{current_namespaces.compact}" if current_namespaces.any?} for #{klass}"
          raise ArSerializer::InvalidQuery, message
        end
        ArSerializer.preload_associations models, field.includes if field.includes.present?
      end

      preload = lambda do |preloader, params|
        has_keyword = preloader.parameters.any? { |type, _name| %i[key keyreq keyrest].include? type }
        arity = preloader.arity.abs
        arguments = [models]
        if has_keyword
          arguments << context unless arity == 2
          preloader.call(*arguments, **(params || {}))
        else
          arguments << context unless arity == 1
          preloader.call(*arguments)
        end
      end

      preloader_values = {}
      if permission == true
        permission_field = klass._serializer_field_info :permission
      elsif permission
        permission_field = klass._serializer_field_info permission
        raise ArgumentError, "No permission field #{permission} for #{klass}" unless permission_field
      end
      if permission_field
        preloadeds = permission_field.preloaders.map do |p|
          preloader_values[[p, nil]] ||= preload.call p, nil
        end
        models = models.select do |model|
          model.instance_exec(*preloadeds, context, {}, &permission_field.data_block)
        end
      end

      defaults = klass._serializer_field_info :defaults
      if defaults
        defaults.preloaders.each do |p|
          preloader_values[[p, nil]] ||= preload.call p, nil
        end
      end

      attributes.each do |name, sub_args|
        field_name = sub_args[:field_name] || name
        klass._serializer_field_info(field_name).preloaders.each do |p|
          params = sub_args[:params]
          preloader_values[[p, params]] ||= preload.call p, params
        end
      end

      models.each do |model|
        output_for_model[model] = {}
      end

      attributes.each do |name, sub_arg|
        params = sub_arg[:params]
        column_name = sub_arg[:column_name] || name
        field_name = sub_arg[:field_name] || name
        info = klass._serializer_field_info field_name
        preloadeds = info.preloaders.map { |p| preloader_values[[p, params]] } || []
        data_block = info.data_block
        permission_block = info.permission
        fallback = info.fallback
        sub_results = {}
        sub_models = []
        models.each do |model|
          next if permission_block && !model.instance_exec(context, **(params || {}), &permission_block)
          child = model.instance_exec(*preloadeds, context, **(params || {}), &data_block)
          if child.is_a?(ArSerializer::ArrayLikeSerializable) || (child.is_a?(Array) && child.any? { |el| el.is_a? ArSerializer::Serializable })
            sub_results[model] = [:multiple, child]
            sub_models << child.grep(ArSerializer::Serializable)
          elsif child.respond_to?(:ar_custom_serializable_models) && child.respond_to?(:ar_custom_serializable_data)
            sub_results[model] = [:custom, child]
            sub_models << child.ar_custom_serializable_models
          elsif child.is_a? ArSerializer::Serializable
            sub_results[model] = [:single, child]
            sub_models << child
          else
            sub_results[model] = [:data, child]
          end
        end

        sub_models.flatten!
        sub_models.uniq!
        unless sub_models.empty?
          sub_attributes = sub_arg[:attributes] || {}
          info.validate_attributes sub_attributes
          result = _serialize(
            sub_models,
            sub_attributes,
            context,
            only: info.only,
            except: info.except,
            permission: info.scoped_access
          )
        end

        models.each do |model|
          data = output_for_model[model]
          type, res = sub_results[model]
          case type
          when :single
            data[column_name] = result[res]
          when :multiple
            arr = data[column_name] = []
            res.each do |r|
              if r.is_a? ArSerializer::Serializable
                arr << result[r] if result.key? r
              else
                arr << r
              end
            end
          when :custom
            data[column_name] = res.ar_custom_serializable_data result || {}
          when :data
            data[column_name] = res
          else
            data[column_name] = fallback
          end
        end
      end

      if defaults
        preloadeds = defaults.preloaders.map { |p| preloader_values[[p]] } || []
        models.each do |model|
          data = model.instance_exec(*preloadeds, context, {}, &defaults.data_block)
          output_for_model[model].update data
        end
      end
    end
    output_for_model
  end

  def self.deep_underscore_keys params
    case params
    when Array
      params.map { |v| deep_underscore_keys v }
    when Hash
      params.transform_keys { |k| k.to_s.underscore.to_sym }.transform_values! do |v|
        deep_underscore_keys v
      end
    else
      params
    end
  end

  def self.parse_args(args, only_attributes: false)
    attributes = []
    params = nil
    column_name = nil
    field_name = nil
    (args.is_a?(Array) ? args : [args]).each do |arg|
      if arg.is_a?(Symbol) || arg.is_a?(String)
        attributes << [arg.to_sym, {}]
      elsif arg.is_a? Hash
        arg.each do |key, value|
          sym_key = key.to_sym
          if !only_attributes && sym_key == :field
            field_name = value
          elsif !only_attributes && sym_key == :as
            column_name = value
          elsif !only_attributes && %i[attributes query].include?(sym_key)
            attributes.concat parse_args(value, only_attributes: true)
          elsif !only_attributes && sym_key == :params
            params = deep_underscore_keys value
          else
            attributes << [sym_key, value == true ? {} : parse_args(value)]
          end
        end
      else
        raise ArSerializer::InvalidQuery, "Arg type missmatch(Symbol, String or Hash): #{arg}"
      end
    end
    return attributes if only_attributes
    { attributes: attributes, column_name: column_name, field_name: field_name, params: params || {} }
  end
end
