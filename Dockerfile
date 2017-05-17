FROM ruby:latest
COPY . /tmp/deb-s3
WORKDIR /tmp/deb-s3
RUN bundle install
ENTRYPOINT [ "bundle", "exec", "deb-s3" ]