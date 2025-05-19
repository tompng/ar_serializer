class ArSerializer::GraphQL::Parser
  class ParseError < StandardError; end

  attr_reader :query, :operation_name, :variables, :chars
  def initialize(query, operation_name: nil, variables: {})
    @query = query
    @operation_name = operation_name
    @variables = variables
    @chars = query.chars
  end

  def self.parse(query, **option)
    new(query, **option).parse
  end

  def parse
    definitions = []
    consume_blank
    loop do
      definition = parse_definition
      consume_blank
      consume_text ','
      consume_blank
      break unless definition
      definitions << definition
    end
    raise_expected_not_found 'definition or EOF' unless chars.empty?
    query = definitions.find do |definition|
      next unless definition[:type] == 'query'
      operation_name.nil? || operation_name == definition[:args].first
    end
    raise ParseError, 'empty query' unless query
    fragments = definitions.select { |definition| definition[:type] == 'fragment' }
    fragments_by_name = fragments.index_by { |frag| frag[:args].first }
    embed_fragment query[:fields], fragments_by_name
  end

  private

  def consume_comment
    return false if chars.first != '#'
    until chars.blank?
      c = chars.first
      break if c == "\n"
      chars.shift
    end
    true
  end

  def consume_blank
    loop do
      chars.shift while chars.first&.match?(/\s/)
      return unless consume_comment
    end
  end

  def consume_text(s)
    return false unless chars.take(s.size).join == s
    chars.shift s.size
    true
  end

  def consume_text!(s)
    return if consume_text s
    raise_expected_not_found s.inspect
  end

  def raise_expected_not_found(expected, found = nil)
    raise(
      ParseError,
      "expected #{expected} but found #{found || chars.first.inspect} #{current_position_message}"
    )
  end

  def parse_name
    name = +''
    name << chars.shift while chars.first && chars.first =~ /[a-zA-Z0-9_]/
    name unless name.empty?
  end

  def parse_name_alias
    name = parse_name
    return unless name
    consume_blank
    if consume_text ':'
      consume_blank
      [parse_name, name]
    else
      name
    end
  end

  def parse_arg_value
    case chars.first
    when '"'
      chars.shift
      s = +''
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
        consume_blank
        value = parse_arg_value
        consume_blank
        consume_text ','
        break if value == :none
        result << value
      end
      consume_text! ']'
      result
    when '{'
      chars.shift
      consume_blank
      result = parse_arg_fields
      consume_blank
      consume_text! '}'
      result
    when '$'
      chars.shift
      name = parse_name
      variables[name]
    when /[0-9+\-]/
      s = +''
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
    result = {}
    loop do
      name = parse_name
      break unless name
      consume_blank
      consume_text! ':'
      consume_blank
      value = parse_arg_value
      if value == :none
        raise(
          ParseError,
          "expected hash value but nothing found #{current_position_message}"
        )
      end
      result[name] = value
      consume_blank
      consume_text ','
      consume_blank
    end
    result
  end

  def parse_args
    return unless consume_text '('
    consume_blank
    args = parse_arg_fields
    consume_blank
    consume_text! ')'
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
    consume_blank
    args = parse_args
    consume_blank
    fields = parse_fields
    [(alias_name || name), { field: name, params: args, attributes: fields }.compact]
  end

  def parse_fields
    return unless consume_text '{'
    consume_blank
    fields = {}
    loop do
      name, field = parse_field
      consume_blank
      consume_text ','
      consume_blank
      break unless name
      fields[name] = field
    end
    consume_text! '}'
    fields
  end

  def parse_definition
    type = parse_name
    consume_blank
    args_text = +''
    if type
      args_text << chars.shift while chars.first && chars.first != '{'
    end
    args = args_text.split(/[\s()]+/)
    fields = parse_fields
    return if type.nil? && fields.nil?
    type ||= 'query'
    raise_expected_not_found '{'.inspect if fields.nil?
    { type: type, args: args, fields: fields }
  end

  def current_position_message
    pos = query.size - chars.size
    code = query[[pos - 10, 0].max..pos + 10]
    line_num = 0
    query.each_line.with_index 1 do |l, i|
      line_num = i
      break if pos < l.size
      pos -= l.size
    end
    "at #{line_num}:#{pos} near #{code.inspect}"
  end

  def embed_fragment(fields, fragments)
    output = {}
    fields.each do |key, value|
      if value.is_a?(Hash) && (fragment_name = value[:fragment])
        fragment = fragments[fragment_name]
        extract_fragment fragment_name, fragments
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

  def extract_fragment(fragment_name, fragments)
    fragment = fragments[fragment_name]
    raise ParseError, "fragment named #{fragment_name.inspect} was not found" if fragment.nil?
    raise ParseError, "fragment circular definition detected in #{fragment_name.inspect}" if fragment[:state] == :start
    return if fragment[:state] == :done
    fragment[:state] = :start
    fragment[:fields] = embed_fragment fragment[:fields], fragments
    fragment[:state] = :done
  end
end
