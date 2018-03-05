module ArSerializer::Serializer
  def self.serialize(model, args, context: nil, include_id: false, use: nil)
    if model.is_a?(ActiveRecord::Base)
      output = {}
      _serialize [[model, output]], parse_args(args), context, include_id, use
      output
    else
      sets = model.to_a.map do |record|
        [record, {}]
      end
      _serialize sets, parse_args(args), context, include_id, use
      sets.map(&:last)
    end
  end

  def self._serialize(mixed_value_outputs, args, context, include_id, namespaces)
    attributes = args[:attributes]
    mixed_value_outputs.group_by { |v, _o| v.class }.each do |klass, value_outputs|
      next unless klass.respond_to? :_serializer_field_info
      models = value_outputs.map(&:first)
      attributes.each_key do |name|
        field = klass._serializer_field_info name, namespaces: namespaces
        raise "No serializer field `#{name}`#{" namespaces: #{namespaces}" if namespaces} for #{klass}" unless field
        ActiveRecord::Associations::Preloader.new.preload models, field.includes if field.includes.present?
      end

      preloader_params = attributes.flat_map do |name, sub_args|
        klass._serializer_field_info(name, namespaces: namespaces).preloaders.map do |p|
          [p, sub_args[:params]]
        end
      end
      preloader_values = preloader_params.compact.uniq.map do |key|
        preloader, params = key
        if preloader.arity < 0
          [key, preloader.call(models, context, params)]
        else
          [key, preloader.call(*[models, context, params].take(preloader.arity))]
        end
      end.to_h

      (include_id ? [[:id, {}], *attributes] : attributes).each do |name, sub_arg|
        params = sub_arg[:params]
        sub_calls = []
        column_name = sub_arg[:column_name] || name
        info = klass._serializer_field_info name, namespaces: namespaces
        args = info.preloaders.map { |p| preloader_values[[p, params]] } || []
        data_block = info.data_block
        value_outputs.each do |value, output|
          child = value.instance_exec(*args, context, params, &data_block)
          is_array_of_model = child.is_a?(Array) && child.grep(ActiveRecord::Base).size == child.size
          if child.is_a?(ActiveRecord::Relation) || is_array_of_model
            array = []
            child.each do |record|
              data = include_id ? { id: record.id } : {}
              array << data
              sub_calls << [record, data]
            end
            output[column_name] = array
          elsif child.is_a? ActiveRecord::Base
            data = include_id ? { id: child.id } : {}
            sub_calls << [child, data]
            output[column_name] = data
          else
            output[column_name] = child
          end
        end
        _serialize sub_calls, sub_arg, context, include_id, namespaces if sub_arg[:attributes]
      end
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
            params = value
          else
            attributes[sym_key] = parse_args(value)
          end
        end
      else
        raise "Arg type missmatch(Symbol, String or Hash): #{arg}"
      end
    end
    return attributes if only_attributes
    { attributes: attributes, column_name: column_name, params: params }
  end
end
