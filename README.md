# ArSerializer

A serializer for ActiveRecord (and plain Ruby objects) where the **client requests the shape of the JSON**, GraphQL-style.

- The client decides which fields and associations to fetch, with a query.
- Associations are batch-loaded, so deeply nested queries avoid N+1 SQL.
- Generates TypeScript type definitions and can serve a GraphQL endpoint.

## Installation

```ruby
gem 'ar_serializer'
```

## Defining fields

```ruby
class User < ActiveRecord::Base
  has_many :posts
  serializer_field :id, :name, :posts
end

class Post < ActiveRecord::Base
  has_many :comments
  serializer_field :id, :title, :body, :comments
  serializer_field :comment_count, count_of: :comments
end

class Comment < ActiveRecord::Base
  serializer_field :id, :body
end
```

## Serializing

```ruby
ArSerializer.serialize(model, query, context: nil, use: nil)
```

```ruby
ArSerializer.serialize Post.find(params[:id]), params[:query]
```

## Query

A query selects fields. Use `:*` for all fields, an array, or a hash; nested
associations take a nested query.

```ruby
ArSerializer.serialize user, :*
# => { id: 1, name: "user1", posts: [{}, {}] }

# Array form and hash form are equivalent:
ArSerializer.serialize user, [:id, :name, posts: [:id, :title, comments: :id]]
ArSerializer.serialize user, { id: true, name: true, posts: { id: true, title: true, comments: :id } }
# => {
#   id: 1,
#   name: "user1",
#   posts: [
#     { id: 2, title: "title1", comments: [{ id: 5 }, { id: 17 }] },
#     { id: 3, title: "title2", comments: [] }
#   ]
# }
```

Rename a field in the output with `as:`:

```ruby
ArSerializer.serialize posts, [:title, :body, comment_count: { as: :num_replies }]
# => [{ title: "title1", body: "body1", num_replies: 3 }, ...]
```

## Field options

### Computed fields (`data block`, `includes`)

Pass a block to compute the value. `includes:` eager-loads the associations the
block needs.

```ruby
class Comment < ActiveRecord::Base
  serializer_field :title, includes: :user do
    "#{user.name}'s comment"
  end
end
```

### Preloading (avoid N+1)

`preload:` receives **all** records being serialized and returns a lookup; the
data block then reads from it per record.

```ruby
class Foo < ActiveRecord::Base
  bar_count_loader = ->(models) do
    Bar.where(foo_id: models.map(&:id)).group(:foo_id).count
  end
  serializer_field :bar_count, preload: bar_count_loader do |preloaded|
    preloaded[id] || 0
  end
  # When the data block is exactly `do |preloaded| preloaded[id] end`, it can be omitted.
end
```

### Counts

```ruby
serializer_field :comment_count, count_of: :comments
```

### Order and limits

Associations accept `order_by`, `direction`, `first`/`last` params.

```ruby
ArSerializer.serialize Post.all, { comments: [:id, params: { order_by: :createdAt, direction: :desc, first: 10 }] }
ArSerializer.serialize Post.all, { comments: [:id, params: { order_by: :updatedAt, last: 10 }] }
```

### Context and params

The block receives the serialize-time `context` and any query `params`.

```ruby
class Post < ActiveRecord::Base
  serializer_field :created_at do |context, **params|
    created_at.in_time_zone(context[:tz]).strftime params[:format]
  end
end
ArSerializer.serialize post, { created_at: { params: { format: '%H:%M:%S' } } }, context: { tz: 'Tokyo' }
```

### camelCase field names

```ruby
class Foo < ActiveRecord::Base
  def foo_bar; end
  serializer_field :fooBar
end
```

### Aliasing an association (`association:`)

Expose an association under a different name.

```ruby
class User < ActiveRecord::Base
  serializer_field :articles, association: :posts
end
ArSerializer.serialize user, { articles: :title }
```

### Restricting fields (`only` / `except`)

Limit which fields of the associated records may be queried. Combine with
`association:` when the field name differs from the association.

```ruby
class User < ActiveRecord::Base
  serializer_field :posts, only: :title                       # restrict
  serializer_field :entries, association: :posts, except: :body  # alias + restrict
end
ArSerializer.serialize user, { posts: :title }    #=> ok
ArSerializer.serialize user, { posts: :body }     #=> Error (not allowed by `only`)
ArSerializer.serialize user, { entries: :title }  #=> ok
ArSerializer.serialize user, { entries: :body }   #=> Error (excluded by `except`)
```

## Access control

### Field-level: `permission:`

Guards a single field. When the predicate returns false the field is omitted
from the output.

```ruby
serializer_field :email, permission: ->(current_user) { current_user&.admin? }
```

### Model-level: `serializer_permission`

Guards every instance of a class, **no matter which query path reaches it**.
When serializing, each candidate object is checked and objects failing the
predicate are dropped — a single reference becomes `null`, an array drops the
element. Useful because any field reachable through the query graph is otherwise
fetchable.

```ruby
class Document < ActiveRecord::Base
  belongs_to :user
  serializer_permission do |current_user|
    current_user && current_user.id == user_id
  end
  serializer_field :id, :title
end
```

## Namespaces

Fields can be grouped into namespaces and exposed only when requested via `use:`.

```ruby
class User < ActiveRecord::Base
  serializer_field :name
  serializer_field(:foo, namespace: :admin) { :foo }
  serializer_field(:bar, namespace: :superadmin) { :bar }
end
ArSerializer.serialize user, [:name, :foo]                          #=> Error
ArSerializer.serialize user, [:name, :foo], use: :admin
ArSerializer.serialize user, [:name, :foo, :bar], use: [:admin, :superadmin]
```

## Non-ActiveRecord classes

Include `ArSerializer::Serializable` to use the DSL on plain Ruby objects.

```ruby
class Foo
  include ArSerializer::Serializable
  def bar; end
  serializer_field :bar
end
```

## TypeScript types

Declare types with `type:` / `params_type:`, then generate `.d.ts`-style
definitions.

```ruby
class User < ActiveRecord::Base
  serializer_field(:posts, params_type: { title: :string? }) do |title: nil|
    title ? posts.where(title: title) : posts
  end
  serializer_field :foobar, type: ['foo', 'bar', { foobar: [:string, nil] }] do
    ['foo', 'bar', { foobar: nil }, { foobar: 'foobar' }].sample
  end
  serializer_field :published_posts, type: -> { [Post] }
end

ArSerializer::TypeScript.generate_type_definition User
# => export type TypeUser = {...}; export type TypePost = {...}; ...
```

## GraphQL

Expose a schema object and serve GraphQL queries against it.

```ruby
class MySchema
  include ArSerializer::Serializable
  serializer_field :post, type: Post do |context, id:|
    Post.find id
  end
  serializer_field :user, type: :string, params_type: { name: :string } do |context, params|
    User.find_by name: params[:name]
  end
  serializer_field :__schema do
    ArSerializer::GraphQL::SchemaClass.new self.class
  end
end

ArSerializer::GraphQL.definition MySchema # schema.graphql
ArSerializer::GraphQL.serialize MySchema.new, '{ post(id: 1){ title } user(name: "user1"){ id name } }'
ArSerializer::GraphQL.serialize MySchema.new, '{ __schema { types { name fields { name } } } }', operation_name: nil, variables: {}
```

## License

[MIT](LICENSE.txt)
