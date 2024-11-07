FROM ruby:3.3-slim

RUN apt-get update -qq && apt-get install -y \
  build-essential \
  libpq-dev \
  curl \
  libxml2-dev \
  libxslt1-dev \
  zlib1g-dev

WORKDIR /app
COPY Gemfile* ./
RUN bundle install

COPY . .

CMD ["rackup", "config.ru", "-o", "0.0.0.0"]
