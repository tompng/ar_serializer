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
ArSerializer.serialize user, [:id, :name, posts: [:id, :title, :comment_count]]
# => {
#   id: 1,
#   name: "user1",
#   posts: [
#     { id: 2, title: "title1", comment_count: 2 },
#     { id: 3, title: "title2", comment_count: 1 }
#   ]
# }
ArSerializer.serialize posts, [:title, body: { as: :BODY }]
# => [
#   { title: "title1", BODY: "body1" },
#   { title: "title2", BODY: "body2" },
#   { title: "title3", BODY: "body3" },
#   { title: "title4", BODY: "body4" }
# ]
```

## その他
```ruby
# data block, include
class Comment
  serializer_field :user, include: :user do
    { name: user.name }
  end
end

# preloader
class Foo
  define_preloader :bar_count_loader do |models|
    Bar.where(foo_id: models.map(&:id)).group(:foo_id).count
  end
  serializer_field :bar_count, preload: (defined_preloader_name or preloader_proc) do |preloaded|
    preloaded[id] || 0
  end
end

# order and limits
# add `gem 'top_n_loader', github: 'tompng/top_n_loader'` to your Gemfile
class Post
  has_many :comments
  serializer_field :comments
end
ArSerializer.serialize Post.all, comments: [:id, params: { order: { id: :desc }, limit: 2 }]

# context and params
class Post
  serializer_field :created_at do |context, params|
    created_at.in_time_zone(context[:tz]).strftime params[:format]
  end
end
ArSerializer.serialize post, { created_at: { params: { format: '%H:%M:%S' } } }, context: { tz: 'Tokyo' }

# namespace
class User
  serializer_field :name
  serializer_field :foo, namespace: :admin
  serializer_field :bar, namespace: :superadmin
end
ArSerializer.serialize user, [:name, :foo] #=> Error
ArSerializer.serialize user, [:name, :foo], use: :admin
ArSerializer.serialize user, [:name, :foo, :bar], use: [:admin, :superadmin]
```
