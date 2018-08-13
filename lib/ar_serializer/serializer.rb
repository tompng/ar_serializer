require 'ar_serializer/error'

class ArSerializer::CompositeValue
  def initialize(pairs:, output:)
    @pairs = pairs
    @output = output
  end

  def ar_serializer_build_sub_calls
    [@output, @pairs]
  end
end

module ArSerializer::ArrayLikeCompositeValue
  def ar_serializer_build_sub_calls
    output = []
    record_elements = []
    each do |record|
      data = {}
      output << data
      record_elements << [record, data]
    end
    [output, record_elements]
  end
end

module ArSerializer::Serializer
  def self.current_namespaces
    Thread.current[:ar_serializer_current_namespaces]
  end

  def self.serialize(model, args, context: nil, include_id: false, use: nil)
    Thread.current[:ar_serializer_current_namespaces] = use
    attributes = parse_args(args)[:attributes]
    if model.is_a?(ArSerializer::Serializable)
      output = {}
      _serialize [[model, output]], attributes, context, include_id
      output
    else
      sets = model.to_a.map do |record|
        [record, {}]
      end
      _serialize sets, attributes, context, include_id
      sets.map(&:last)
    end
  ensure
    Thread.current[:ar_serializer_current_namespaces] = nil
  end

  def self._serialize(mixed_value_outputs, attributes, context, include_id, only = nil, except = nil)
    mixed_value_outputs.group_by { |v, _o| v.class }.each do |klass, value_outputs|
      next unless klass.respond_to? :_serializer_field_info
      models = value_outputs.map(&:first)
      value_outputs.each { |value, output| output[:id] = value.id } if include_id && klass.method_defined?(:id)
      if attributes[:*]
        all_keys = klass._serializer_field_keys.map(&:to_sym)
        all_keys &= only.map(&:to_sym) if only
        all_keys -= except.map(&:to_sym) if except
        attributes = all_keys.map { |k| [k, {}] }.to_h.merge attributes
        attributes.delete :*
      end
      attributes.each_key do |name|
        field = klass._serializer_field_info name
        raise ArSerializer::InvalidQuery, "No serializer field `#{name}`#{" namespaces: #{current_namespaces}" if current_namespaces} for #{klass}" unless field
        ActiveRecord::Associations::Preloader.new.preload models, field.includes if field.includes.present?
      end

      preloader_params = attributes.flat_map do |name, sub_args|
        klass._serializer_field_info(name).preloaders.map do |p|
          [p, sub_args[:params]]
        end
      end
      defaults = klass._serializer_field_info(:defaults)
      if defaults
        preloader_params += defaults.preloaders.map { |p| [p] }
      end
      preloader_values = preloader_params.compact.uniq.map do |key|
        preloader, params = key
        if preloader.arity < 0
          [key, preloader.call(models, context, params)]
        else
          [key, preloader.call(*[models, context, params].take(preloader.arity))]
        end
      end.to_h

      if defaults
        preloadeds = defaults.preloaders.map { |p| preloader_values[[p]] } || []
        value_outputs.each do |value, output|
          data = value.instance_exec(*preloadeds, context, nil, &defaults.data_block)
          output.update data
        end
      end

      attributes.each do |name, sub_arg|
        params = sub_arg[:params]
        sub_calls = []
        column_name = sub_arg[:column_name] || name
        info = klass._serializer_field_info name
        preloadeds = info.preloaders.map { |p| preloader_values[[p, params]] } || []
        data_block = info.data_block
        value_outputs.each do |value, output|
          child = value.instance_exec(*preloadeds, context, params, &data_block)
          if child.is_a?(Array) && child.all? { |el| el.is_a? ArSerializer::Serializable }
            output[column_name] = child.map do |record|
              data = {}
              sub_calls << [record, data]
              data
            end
          elsif child.respond_to? :ar_serializer_build_sub_calls
            sub_output, record_elements = child.ar_serializer_build_sub_calls
            record_elements.each { |o| sub_calls << o }
            output[column_name] = sub_output
          elsif child.is_a? ArSerializer::CompositeValue
            sub_output, record_elements = child.build
            record_elements.each { |o| sub_calls << o }
            output[column_name] = sub_output
          elsif child.is_a? ArSerializer::Serializable
            data = {}
            sub_calls << [child, data]
            output[column_name] = data
          else
            output[column_name] = child
          end
        end
        next if sub_calls.empty?
        sub_attributes = sub_arg[:attributes] || {}
        info.validate_attributes sub_attributes
        _serialize sub_calls, sub_attributes, context, include_id, info.only, info.except
      end
    end
  end

  def self.deep_with_indifferent_access params
    case params
    when Array
      params.map { |v| deep_with_indifferent_access v }
    when Hash
      params.transform_keys(&:to_sym).transform_values! do |v|
        deep_with_indifferent_access v
      end
    else
      params
    end
  end

  def self.parse_args(args, only_attributes: false)
    attributes = {}
    params = nil
    column_name = nil
    (args.is_a?(Array) ? args : [args]).each do |arg|
      if arg.is_a?(Symbol) || arg.is_a?(String)
        attributes[arg.to_sym] = {}
      elsif arg.is_a? Hash
        arg.each do |key, value|
          sym_key = key.to_sym
          if only_attributes
            attributes[sym_key] = parse_args(value)
            next
          end
          if sym_key == :as
            column_name = value
          elsif sym_key == :attributes
            attributes.update parse_args(value, only_attributes: true)
          elsif sym_key == :params
            params = deep_with_indifferent_access value
          else
            attributes[sym_key] = parse_args(value)
          end
        end
      else
        raise ArSerializer::InvalidQuery, "Arg type missmatch(Symbol, String or Hash): #{arg}"
      end
    end
    return attributes if only_attributes
    { attributes: attributes, column_name: column_name, params: params }
  end
end
