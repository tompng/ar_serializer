require_relative 'graphql/types'
require_relative 'graphql/parser'

module ArSerializer::GraphQL
  def self.definition(klass, use: nil)
    ArSerializer::Serializer.with_namespaces(use) { _definition klass }
  end

  def self._definition(klass)
    schema = SchemaClass.new(klass)
    definitions = schema.types.map do |type|
      next "scalar #{type.name}" if type.is_a? ScalarTypeClass
      fields = type.fields.map do |field|
        args = field.args.map { |arg| "#{arg.name}: #{arg.type.gql_type}" }
        args_exp = "(#{args.join(', ')})" unless args.empty?
        "  #{field.name}#{args_exp}: #{field.type.gql_type}"
      end
      <<~TYPE
        type #{type.name} {
        #{fields.join("\n")}
        }
      TYPE
    end
    <<~SCHEMA
      schema {
        query: #{schema.query_type.name}
      }

      #{definitions.map(&:strip).join("\n\n")}
    SCHEMA
  end

  def self.serialize(schema, gql_query, operation_name: nil, variables: {}, **args)
    query = ArSerializer::GraphQL::Parser.parse(
      gql_query,
      operation_name: operation_name,
      variables: variables
    )
    { data: ArSerializer::Serializer.serialize(schema, query, **args) }
  end
end
