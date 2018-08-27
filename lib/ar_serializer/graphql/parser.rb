class ArSerializer::GraphQL::Parser
  attr_reader :query, :operation_name, :variables, :chars
  def initialize(query, operation_name: nil, variables: {})
    @query = query
    @operation_name = operation_name
    @variables = variables
    @chars = query.chars
  end

  def self.parse(*args)
    new(*args).parse
  end

  def parse
    definitions = []
    loop do
      definition = parse_definition
      break unless definition
      definitions << definition
    end
    raise unless chars.empty?

    query = definitions.find do |definition|
      next unless definition[:type] == 'query'
      operation_name.nil? || operation_name == definition[:args].first
    end
    fragments = definitions.select { |definition| definition[:type] == 'fragment' }
    fragments_by_name = fragments.index_by { |frag| frag[:args].first }
    embed_fragment query[:fields], fragments_by_name
  end

  private

  def consume_blank
    chars.shift while chars.first == ' ' || chars.first == "\n"
  end

  def consume_space
    chars.shift while chars.first == ' '
  end

  def consume_text(s)
    return false unless chars.take(s.size).join == s
    chars.shift s.size
    true
  end

  def parse_name
    name = ''
    name << chars.shift while chars.first && chars.first =~ /[a-zA-Z0-9_]/
    name unless name.empty?
  end

  def parse_name_alias
    name = parse_name
    return unless name
    consume_space
    if consume_text ':'
      consume_space
      [parse_name, name]
    else
      name
    end
  end

  def parse_arg_value
    consume_blank
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
      unescape_string s
    when '['
      chars.shift
      result = []
      loop do
        value = parse_arg_value
        consume_text ','
        break if value == :none
        result << value
      end
      raise unless consume_text ']'
      result
    when '{'
      chars.shift
      result = parse_arg_fields
      raise unless consume_text '}'
      result
    when '$'
      chars.shift
      name = parse_name
      variables[name]
    when /[0-9+\-]/
      s = ''
      s << chars.shift while chars.first.match?(/[0-9.e+\-]/)
      s.match?(/\.|e/) ? s.to_f : s.to_i
    when /[a-zA-Z]/
      s = parse_name
      converts = { 'true' => true, 'false' => false, 'null' => nil }
      converts.key?(s) ? converts[s] : s
    else
      :none
    end
  end

  def unescape_string(s)
    JSON.parse %("#{s}")
  rescue JSON::ParserError # for old json gem
    JSON.parse(%(["#{s}"])).first
  end

  def parse_arg_fields
    consume_blank
    result = {}
    loop do
      name = parse_name
      break unless name
      consume_blank
      raise unless consume_text ':'
      consume_blank
      value = parse_arg_value
      raise if value == :none
      result[name] = value
      consume_blank
      consume_text ','
      consume_blank
    end
    consume_blank
    result
  end

  def parse_args
    return unless consume_text '('
    args = parse_arg_fields
    raise unless consume_text ')'
    args
  end

  def parse_field
    if chars[0, 3].join == '...'
      3.times { chars.shift }
      name = parse_name
      return ['...' + name, { fragment: name }]
    end
    name, alias_name = parse_name_alias
    return unless name
    consume_space
    args = parse_args
    consume_space
    fields = parse_fields
    [name, { as: alias_name, params: args, attributes: fields }.compact]
  end

  def parse_fields
    consume_blank
    return unless consume_text '{'
    consume_blank
    fields = {}
    loop do
      name, field = parse_field
      consume_blank
      break unless name
      fields[name] = field
    end
    raise unless consume_text '}'
    fields
  end

  def parse_definition
    consume_blank
    definition_types = ''
    definition_types << chars.shift while chars.first&.match?(/[^{}]/)
    fields = parse_fields
    consume_blank
    return unless fields
    type, *args = definition_types.split(/[\s()]+/)
    type ||= 'query'
    { type: type, args: args, fields: fields }
  end

  def embed_fragment(fields, fragments)
    output = {}
    fields.each do |key, value|
      if value.is_a?(Hash) && (fragment_name = value[:fragment])
        fragment = fragments[fragment_name]
        extract_fragment fragment, fragments
        output.update fragment[:fields]
      else
        output[key] = value
        if (attrs = value[:attributes])
          value[:attributes] = embed_fragment attrs, fragments
        end
      end
    end
    output
  end

  def extract_fragment(fragment, fragments)
    raise if fragment[:state] == :start
    return if fragment[:state] == :done
    fragment[:state] = :start
    fragment[:fields] = embed_fragment fragment[:fields], fragments
    fragment[:state] = :done
  end
end
