require 'yaml'
require 'logger'
require 'active_record'
require 'active_record/schema_dumper'
require 'active_record/fixtures'

config_dir = File.expand_path("#{$APP_ROOT}/config", __FILE__)
db_dir = File.expand_path("#{$APP_ROOT}/db", __FILE__)
fixtures_dir = File.expand_path("#{$APP_ROOT}/db/fixtures", __FILE__)

include ActiveRecord::Tasks

desc "DB related operations"
namespace :db do

  task :environment do
    RACK_ENV = ENV['DATABASE_URL'] || 'development'
    MIGRATIONS_DIR = ENV['MIGRATIONS_DIR'] || 'db/migrate'
  end

  task :configuration => :environment do
    config_file = File.expand_path('../../../config/database.yml', __FILE__)
    if $RACK_ENV == 'production'
      @config = ENV["DATABASE_URL"]
    else
      @config = YAML.load_file('config/database.yml')[$RACK_ENV]
    end
  end

  task :configure_connection => :configuration do
    ActiveRecord::Base.establish_connection @config
    ActiveRecord::Base.logger = Logger.new STDOUT if @config['logger']
  end

  task :load_models do
    Dir["#{$APP_ROOT}/models/*.rb"].each {|file| require file }
  end

  desc 'Create the database from config/database.yml for the current DATABASE_ENV'
  task :create => :configure_connection do
    create_database @config
  end

  desc 'Drops the database for the current DATABASE_ENV'
  task :drop => :configure_connection do
    ActiveRecord::Base.connection.drop_database @config['database']
  end

  desc 'Resets your database using your migrations for the current environment (Non-SQLite DB)'
  task :reset => ['db:drop', 'db:create', 'db:migrate']

  desc 'Resets your database using your migrations for the current environment (Non-SQLite DB)'
  task :reset_lite do
    Rake::Task["db:migrate"].invoke("VERSION=0")
    Rake::Task["db:migrate"].invoke
  end

  desc 'Migrate the database (options: VERSION=x, VERBOSE=false).'
  task :migrate => :configure_connection do
    ActiveRecord::Migration.verbose = true
    ActiveRecord::Migrator.migrate MIGRATIONS_DIR, ENV['VERSION'] ? ENV['VERSION'].to_i : nil
    Rake::Task["db:schema:dump"].invoke
  end

  namespace :schema do
    task :dump => :configure_connection do
      File.open("db/schema.rb", "w") do |file|
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, file)
      end
    end

    desc 'Load a schema.rb file into the database'
    task :load => :configure_connection do
      load('db/schema.rb')
    end
  end

  desc 'Rolls the schema back to the previous version (specify steps w/ STEP=n).'
  task :rollback => :configure_connection do
    step = ENV['STEP'] ? ENV['STEP'].to_i : 1
    ActiveRecord::Migrator.rollback MIGRATIONS_DIR, step
  end

  desc "Retrieves the current schema version number"
  task :version => :configure_connection do
    puts "Current version: #{ActiveRecord::Migrator.current_version}"
  end

  desc "create an ActiveRecord migration in ./db/migrate"
  task :create_migration do
    name = ENV['NAME']
    abort("no NAME specified. use `rake db:create_migration NAME=create_users`") if !name

    migrations_dir = File.join("db", "migrate")
    version = ENV["VERSION"] || Time.now.utc.strftime("%Y%m%d%H%M%S")
    filename = "#{version}_#{name}.rb"
    migration_name = name.gsub(/_(.)/) { $1.upcase }.gsub(/^(.)/) { $1.upcase }

    FileUtils.mkdir_p(migrations_dir)

    open(File.join(migrations_dir, filename), 'w') do |f|
      f << (<<-EOS).gsub("      ", "")
      class #{migration_name} < ActiveRecord::Migration
        def change
        end
      end
      EOS
    end
  end

  namespace :fixtures do
    desc "Loads fixtures into the current environment's database. Load specific fixtures using FIXTURES=x,y. Load from subdirectory in test/fixtures using FIXTURES_DIR=z. Specify an alternative path (eg. spec/fixtures) using FIXTURES_PATH=spec/fixtures."
    task :load => [:environment, :configuration, :configure_connection, :load_models] do
      fixtures_dir = if ENV['FIXTURES_DIR']
                       File.join base_dir, ENV['FIXTURES_DIR']
                     else
                       fixtures_dir
                     end

      fixture_files = if ENV['FIXTURES']
                        ENV['FIXTURES'].split(',')
                      else
                        # The use of String#[] here is to support namespaced fixtures
                        Dir["#{fixtures_dir}/**/*.yml"].map {|f| f[(fixtures_dir.size + 1)..-5] }
                      end
      puts "Invoking create_fixtures for models #{fixture_files}"
      ActiveRecord::FixtureSet.create_fixtures(fixtures_dir, fixture_files)
      puts "Fixtures loaded successfully!"
    end

    desc "Search for a fixture given a LABEL or ID. Specify an alternative path (eg. spec/fixtures) using FIXTURES_PATH=spec/fixtures."
    task :identify => [:environment, :load_config] do
      require 'active_record/fixtures'

      label, id = ENV['LABEL'], ENV['ID']
      raise 'LABEL or ID required' if label.blank? && id.blank?

      puts %Q(The fixture ID for "#{label}" is #{ActiveRecord::FixtureSet.identify(label)}.) if label

      base_dir = ActiveRecord::Tasks::DatabaseTasks.fixtures_path

      Dir["#{base_dir}/**/*.yml"].each do |file|
        if data = YAML::load(ERB.new(IO.read(file)).result)
          data.each_key do |key|
            key_id = ActiveRecord::FixtureSet.identify(key)

            if key == label || key_id == id.to_i
              puts "#{file}: #{key} (#{key_id})"
            end
          end
        end
      end
    end
  end

end
