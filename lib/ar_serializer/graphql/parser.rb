module ArSerializer::GraphQL::QueryParser
  def self.parse(query, operation_name: nil, variables: {})
    chars = query.chars
    consume_blank = lambda do
      chars.shift while chars.first == ' ' || chars.first == "\n"
    end
    consume_space = lambda do
      chars.shift while chars.first == ' '
    end
    consume_pattern = lambda do |pattern|
      return unless chars.take(pattern.size).join == pattern
      chars.shift pattern.size
      true
    end
    parse_name = lambda do
      name = ''
      name << chars.shift while chars.first && chars.first =~ /[a-zA-Z0-9_]/
      name unless name.empty?
    end
    parse_name_alias = lambda do
      name = parse_name.call
      return unless name
      consume_space.call
      if consume_pattern.call ':'
        consume_space.call
        [parse_name.call, name]
      else
        name
      end
    end
    parse_arg_fields = nil
    parse_arg_value = lambda do
      consume_blank.call
      case chars.first
      when '"'
        chars.shift
        s = ''
        loop do
          if chars.first == '\\'
            s << chars.shift
            s << chars.shift
          elsif chars.first == '"'
            break
          else
            s << chars.shift
          end
        end
        chars.shift
        JSON.parse %("#{s}")
      when '['
        chars.shift
        result = []
        loop do
          value = parse_arg_value.call
          consume_pattern.call ','
          break if value == :none
          result << value
        end
        raise unless consume_pattern.call ']'
        result
      when '{'
        chars.shift
        result = parse_arg_fields.call
        raise unless consume_pattern.call '}'
        result
      when '$'
        chars.shift
        name = parse_name.call
        variables[name]
      when /[0-9+\-]/
        s = ''
        s << chars.shift while chars.first.match?(/[0-9.e+\-]/)
        s.match?(/\.|e/) ? s.to_f : s.to_i
      when /[a-zA-Z]/
        s = parse_name.call
        converts = { 'true' => true, 'false' => false, 'null' => nil }
        converts.key?(s) ? converts[s] : s
      else
        :none
      end
    end

    parse_arg_fields = lambda do
      consume_blank.call
      result = {}
      loop do
        name = parse_name.call
        break unless name
        consume_blank.call
        raise unless consume_pattern.call ':'
        consume_blank.call
        value = parse_arg_value.call
        raise if value == :none
        result[name] = value
        consume_blank.call
        consume_pattern.call ','
        consume_blank.call
      end
      consume_blank.call
      result
    end

    parse_args = lambda do
      return unless consume_pattern.call '('
      args = parse_arg_fields.call
      raise unless consume_pattern.call ')'
      return args
    end
    parse_fields = nil
    parse_field = lambda do
      if chars[0,3].join == '...'
        3.times { chars.shift }
        name = parse_name.call
        return ['...' + name, { fragment: name }]
      end
      name, alias_name = parse_name_alias.call
      return unless name
      consume_space.call
      args = parse_args.call
      consume_space.call
      fields = parse_fields.call
      [name, { as: alias_name, params: args, attributes: fields }.compact]
    end
    parse_fields = lambda do
      consume_blank.call
      return unless consume_pattern.call '{'
      consume_blank.call
      fields = {}
      loop do
        name, field = parse_field.call
        consume_blank.call
        break unless name
        fields[name] = field
      end
      raise unless consume_pattern.call '}'
      fields
    end
    parse_definition = lambda do
      consume_blank.call
      definition_types = ''
      definition_types << chars.shift while chars.first&.match?(/[^{}]/)
      fields = parse_fields.call
      consume_blank.call
      return unless fields
      type, *args = definition_types.split(/[\s()]+/)
      type ||= 'query'
      { type: type, args: args, fields: fields }
    end
    definitions = []
    loop do
      definition = parse_definition.call
      break unless definition
      definitions << definition
    end
    raise unless chars.empty?

    query = definitions.find do |definition|
      next unless definition[:type] == 'query'
      operation_name.nil? || operation_name == definition[:args].first
    end
    fragments = definitions.select { |definition| definition[:type] == 'fragment' }
    fragments_by_name = fragments.map { |frag| [frag[:args].first, frag] }.to_h

    embed_fragment = nil
    extract_fragment = lambda do |fragment|
      raise if fragment[:state] == :start
      return if fragment[:state] == :done
      fragment[:state] = :start
      fragment[:fields] = embed_fragment.call fragment[:fields]
      fragment[:state] = :done
    end

    embed_fragment = lambda do |fields|
      output = {}
      fields.each do |key, value|
        if value.is_a?(Hash) && value[:fragment]
          fragment = fragments_by_name[value[:fragment]]
          extract_fragment.call fragment
          output.update fragment[:fields]
        else
          output[key] = value
          value[:attributes] = embed_fragment.call value[:attributes] if value[:attributes]
        end
      end
      output
    end
    embed_fragment.call query[:fields]
  end
end
