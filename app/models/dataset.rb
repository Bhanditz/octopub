# == Schema Information
#
# Table name: datasets
#
#  id              :integer          not null, primary key
#  name            :string(255)
#  url             :string(255)
#  user_id         :integer
#  created_at      :datetime
#  updated_at      :datetime
#  repo            :string(255)
#  description     :text
#  publisher_name  :string(255)
#  publisher_url   :string(255)
#  license         :string(255)
#  frequency       :string(255)
#  datapackage_sha :text
#  owner           :string(255)
#  owner_avatar    :string(255)
#  build_status    :string(255)
#  full_name       :string(255)
#  certificate_url :string(255)
#  job_id          :string(255)
#

require 'git_data'
require 'open-uri'
require 'open_uri_redirections'

class Dataset < ApplicationRecord

  belongs_to :user
  has_many :dataset_files

  after_create :create_in_github, :set_owner_avatar, :build_certificate, :send_success_email, :send_tweet_notification
  after_update :update_in_github
  after_destroy :delete_in_github

  attr_accessor :schema

  validate :check_schema
  validate :check_repo, on: :create
  validates_associated :dataset_files

  def report_status(channel_id)
    if valid?
      Pusher[channel_id].trigger('dataset_created', self) if channel_id
      save
    else
      messages = errors.full_messages
      dataset_files.each do |file|
        unless file.valid?
          (file.errors.messages[:file] || []).each do |message|
            messages << "Your file '#{file.title}' #{message}"
          end
        end
      end
      if channel_id
        Pusher[channel_id].trigger('dataset_failed', messages.uniq)
      else
        Error.create(job_id: self.job_id, messages: messages.uniq)
      end
    end
  end

  def create_contents(filename, file)
    @repo.add_file(filename, file)
  end

  def update_contents(filename, file)
    @repo.update_file(filename, file)
  end

  def delete_contents(filename)
    @repo.delete_file(filename)
  end

  def path(filename, folder = "")
    File.join([folder,filename].reject { |n| n.blank? })
  end

  def create_files
    create_datapackage
    create_contents("index.html", File.open(File.join(Rails.root, "extra", "html", "index.html")).read)
    create_contents("_config.yml", config)
    create_contents("css/style.css", File.open(File.join(Rails.root, "extra", "stylesheets", "style.css")).read)
    create_contents("_layouts/default.html", File.open(File.join(Rails.root, "extra", "html", "default.html")).read)
    create_contents("_layouts/resource.html", File.open(File.join(Rails.root, "extra", "html", "resource.html")).read)
    create_contents("_layouts/api-item.html", File.open(File.join(Rails.root, "extra", "html", "api-item.html")).read)
    create_contents("_layouts/api-list.html", File.open(File.join(Rails.root, "extra", "html", "api-list.html")).read)
    create_contents("_includes/data_table.html", File.open(File.join(Rails.root, "extra", "html", "data_table.html")).read)
    create_contents("js/papaparse.min.js", File.open(File.join(Rails.root, "extra", "js", "papaparse.min.js")).read)
    if !schema.nil?
      create_contents("schema.json", open(schema).read)
      dataset_files.each { |f| f.send(:create_json_api_files, parsed_schema) }
    end
  end

  def create_datapackage
    create_contents("datapackage.json", datapackage)
  end

  def update_datapackage
    update_contents("datapackage.json", datapackage)
  end

  def datapackage
    datapackage = {}

    datapackage["name"] = name.downcase.parameterize
    datapackage["title"] = name
    datapackage["description"] = description
    datapackage["licenses"] = [{
      "url"   => license_details.url,
      "title" => license_details.title
    }]
    datapackage["publishers"] = [{
      "name"   => publisher_name,
      "web" => publisher_url
    }]

    datapackage["resources"] = []

    dataset_files.each do |file|
      datapackage["resources"] << {
        "name" => file.title,
        "mediatype" => 'text/csv',
        "description" => file.description,
        "path" => "data/#{file.filename}",
        "schema" => (JSON.parse(open(schema).read) unless schema.nil? || is_csv_otw?)
      }.delete_if { |k,v| v.nil? }
    end

    datapackage.to_json
  end

  def config
    {
      "data_dir" => '.',
      "update_frequency" => frequency,
      "permalink" => 'pretty'
    }.to_yaml
  end

  def license_details
    Odlifier::License.define(license)
  end

  def github_url
    "http://github.com/#{full_name}"
  end

  def gh_pages_url
    "http://#{repo_owner}.github.io/#{repo}"
  end

  def full_name
    "#{repo_owner}/#{repo}"
  end

  def repo_owner
    owner.presence || user.github_username
  end

  def fetch_repo(client = user.octokit_client)
    begin
      @repo = GitData.find(repo_owner, self.name, client: client)
      check_for_schema
    rescue Octokit::NotFound
      @repo = nil
    end
  end

  def check_for_schema
    begin
      open(schema_url, allow_redirections: :safe)
      self.schema = schema_url
    rescue OpenURI::HTTPError
      nil
    end
  end

  def schema_url
    "#{gh_pages_url}/schema.json"
  end

  def parsed_schema
    return nil if schema.nil?
    schema.instance_variable_get("@parsed_schema") || parse_schema!
  end

  private

    def create_in_github
      @repo = GitData.create(repo_owner, name, private: private, client: user.octokit_client)
      self.update_columns(url: @repo.html_url, repo: @repo.name, full_name: @repo.full_name)
      commit
    end

    def commit
      dataset_files.each { |d| d.add_to_github }
      create_files
      push_to_github
    end

    def update_in_github
      dataset_files.each { |d| d.update_in_github if d.file }
      update_datapackage
      push_to_github
    end

    def delete_in_github
      @repo.delete if @repo
    end

    def push_to_github
      @repo.save
    end

    def check_schema
      return nil unless schema

      if is_csv_otw?
        unless parsed_schema.tables[parsed_schema.tables.keys.first].columns.first
          errors.add :schema, 'is invalid'
        end
      else
        unless parsed_schema.fields.first
          errors.add :schema, 'is invalid'
        end
      end
    end

    def check_repo
      repo_name = "#{repo_owner}/#{name.parameterize}"
      if user.octokit_client.repository?(repo_name)
        errors.add :repository_name, 'already exists'
      end
    end

    def parse_schema!
      if schema.instance_variable_get("@parsed_schema").nil?
        schema.instance_variable_set("@parsed_schema", Csvlint::Schema.load_from_json(schema))
      end
    end

    def is_csv_otw?
      return false if schema.nil?
      parsed_schema.class == Csvlint::Csvw::TableGroup
    end

    def set_owner_avatar
      if owner.blank?
        update_column :owner_avatar, user.avatar
      else
        update_column :owner_avatar, Rails.configuration.octopub_admin.organization(owner).avatar_url
      end
    end

    def send_success_email
      DatasetMailer.success(self).deliver
    end

    def send_tweet_notification
      if ENV["TWITTER_CONSUMER_KEY"] && user.twitter_handle
        twitter_client = Twitter::REST::Client.new do |config|
          config.consumer_key        = ENV["TWITTER_CONSUMER_KEY"]
          config.consumer_secret     = ENV["TWITTER_CONSUMER_SECRET"]
          config.access_token        = ENV["TWITTER_TOKEN"]
          config.access_token_secret = ENV["TWITTER_SECRET"]
        end
        twitter_client.update("@#{user.twitter_handle} your dataset \"#{self.name}\" is now published at #{self.gh_pages_url}")
      end
    end

    def build_certificate
      status = user.octokit_client.pages(full_name).status

      if status == "built"
        create_certificate
      else
        retry_certificate
      end
    end

    def retry_certificate
      sleep 5
      build_certificate
    end

    def create_certificate
      cert = CertificateFactory::Certificate.new gh_pages_url

      gen = cert.generate

      if gen[:success] == 'pending'
        result = cert.result
        add_certificate_url(result[:certificate_url])
      end
    end

    def add_certificate_url(url)
      return if url.nil?

      url = url.gsub('.json', '')
      update_column(:certificate_url, url)

      config = {
        "data_source" => ".",
        "update_frequency" => frequency,
        "certificate_url" => "#{certificate_url}/badge.js"
      }.to_yaml

      fetch_repo(user.octokit_client)
      update_contents('_config.yml', config)
      push_to_github
    end

end
