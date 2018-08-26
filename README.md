# ArSerializer

- JSONの形をclientからリクエストできる
- N+1 SQLを避ける

## Install

```ruby
gem 'ar_serializer', github: 'tompng/ar_serializer'
```

## Field定義
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

## Serialize
```ruby
ArSerializer.serialize Post.find(params[:id]), params[:query]
```

## Query
```ruby
ArSerializer.serialize user, :*
# => {
#   id: 1,
#   name: "user1",
#   posts: [{}, {}]
# }

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
ArSerializer.serialize posts, [:title, :body, comment_count: { as: :num_replies }]
# => [
#   { title: "title1", body: "body1", num_replies: 3 },
#   { title: "title2", body: "body2", num_replies: 2 },
#   { title: "title3", body: "body3", num_replies: 0 },
#   { title: "title4", body: "body4", num_replies: 4 }
# ]
```

## その他
```ruby
# data block, include
class Comment < ActiveRecord::Base
  serializer_field :username, includes: :user do
    { ja: user.name + '先生', en: 'Dr.' + user.name }
  end
end

# preloader
class Foo < ActiveRecord::Base
  define_preloader :bar_count_loader do |models|
    Bar.where(foo_id: models.map(&:id)).group(:foo_id).count
  end
  serializer_field :bar_count, preload: preloader_name_or_proc do |preloaded|
    preloaded[id] || 0
  end
  # data_blockが `do |preloaded| preloaded[id] end` の場合は省略可能
end

# order and limits
# add `gem 'top_n_loader', github: 'tompng/top_n_loader'` to your Gemfile
class Post < ActiveRecord::Base
  has_many :comments
  serializer_field :comments
end
ArSerializer.serialize Post.all, comments: [:id, params: { order: { id: :desc }, limit: 2 }]

# context and params
class Post < ActiveRecord::Base
  serializer_field :created_at do |context, params|
    created_at.in_time_zone(context[:tz]).strftime params[:format]
  end
end
ArSerializer.serialize post, { created_at: { params: { format: '%H:%M:%S' } } }, context: { tz: 'Tokyo' }

# camelcase
class Foo < ActiveRecord::Base
  def foo_bar; end
  serializer_field :fooBar
end

# non activerecord class
class Foo
  include ArSerializer::Serializable
  def bar; end
  serializer_field :bar
end

# namespace
class User < ActiveRecord::Base
  serializer_field :name
  serializer_field(:foo, namespace: :admin) { :foo }
  serializer_field(:bar, namespace: :superadmin) { :bar }
end
ArSerializer.serialize user, [:name, :foo] #=> Error
ArSerializer.serialize user, [:name, :foo], use: :admin
ArSerializer.serialize user, [:name, :foo, :bar], use: [:admin, :superadmin]

# only, except
class User < ActiveRecord::Base
  serializer_field :o_posts, association: :posts, only: :title
  serializer_field :e_posts, association: :posts, except: :comments
end
ArSerializer.serialize user, o_posts: :title, e_posts: :body
ArSerializer.serialize user, o_posts: :*, e_posts: :*
ArSerializer.serialize user, o_posts: :body #=> Error
ArSerializer.serialize user, e_posts: :comments #=> Error

# type annotation and graphql
class MySchema
  include ArSerializer::Serializable
  serializer_field :post, type: Post do |context, id:|
    Post.find id
  end
  serializer_field :user, type: :string, params_type: { name: :string! } do |context, params|
    User.find_by name: params[:name]
  end
  serializer_field :__schema do
    ArSerializer::GraphQL::SchemaClass.new self.class
  end
end
ArSerializer::GraphQL.definition MySchema # schema.graphql
ArSerializer::GraphQL.serialize MySchema.new, '{post(id: 1){title} user(name: user1){id name}}'
ArSerializer::GraphQL.serialize MySchema.new, '{__schema{types{name fields{ name}}}}', operation_name: nil, variables: {}
```
