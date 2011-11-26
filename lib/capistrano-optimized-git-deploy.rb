# Copyright (c) 2009-2011 by Ewout Vonk. All rights reserved.
# Copyright (c) 2009 by Brian Landau, Viget.
# Copyright (c) 2009 by defunkt.

# Applied a comment by Andreas Fuchs (antifuchs) on https://github.com/blog/470-deployment-script-spring-cleaning.

# prevent loading when called by Bundler, only load when called by capistrano
if caller.any? { |callstack_line| callstack_line =~ /^Capfile:/ }
  unless Capistrano::Configuration.respond_to?(:instance)
    abort "capistrano-optimized-git-deploy requires Capistrano 2"
  end

  Capistrano::Configuration.instance(:must_exist).load do
  
    GIT_REMOTE = (`git remote show -n origin`.split(/\n/).grep(/^\s+Fetch URL:\s+/).first || '').gsub(/^\s+Fetch\s+URL:\s+(\S+)\s*$/, '\1')
    APPLICATION_NAME = File.basename(GIT_REMOTE.split(/:|\//).last, '.git')

    # courtesy provided by this gem. If you're including this gem and requiring it from config/deploy.rb, you must want to enable it anyway
    set :repository, GIT_REMOTE
    set :application, APPLICATION_NAME
    set :deploy_via, :checkout
    set :scm, :git

    set(:left_release)         { File.join(releases_path, 'left') }
    set(:right_release)        { File.join(releases_path, 'right') }    

    set(:current_release_name) { (current_release_name = capture("[ -L #{current_path} -a -e #{current_path} ] && { touch #{left_release}/LEFT #{right_release}/RIGHT ; cd #{current_path} ; find . -name 'LEFT' -o -name 'RIGHT' | cut -c 3- ; rm -f #{left_release}/LEFT #{right_release}/RIGHT ; }")).empty? ? 'right' : current_release_name }
    set(:release_name)         { set :deploy_timestamped, true; current_release_name == "left" ? "right" : "left" }
    set(:releases)             { capture("ls -x #{releases_path}").split.map { |d| d =~ /^left|right$/ ? d : nil }.compact.sort }

    set(:current_release)      { File.join(releases_path, current_release_name) }
    set(:previous_release)     { release_path }

    set(:current_revision)     { capture("cd #{current_release}; git rev-parse --short HEAD").strip }
    set(:latest_revision)      { capture("cd #{latest_release}; git rev-parse --short HEAD").strip }
    set(:previous_revision)    { capture("cd #{previous_release}; git rev-parse --short HEAD@{1}").strip }

    after 'deploy:rollback:revision', 'deploy:rollback:db'

    namespace :deploy do

      desc "Update the deployed code."
      task :update_code, :except => { :no_release => true } do
        run ([ left_release, right_release ].map do |release_dir|
          "[ -d #{release_dir} ] || #{source.checkout(branch, release_dir)}"
        end + [ "#{source.sync(branch, release_path)}" ]).join(" ;\n")

        finalize_update
      end

      desc "Does nothing, we don't keep old releases. (overridden from capistrano)"
      task :cleanup, :roles => [:app, :web, :db], :except => { :no_release => true } do
      end

      namespace :rollback do

        desc "Rollback to the previous release (overridden from capistrano)"
        task :revision, :except => { :no_release => true } do
          set :branch, "HEAD@{1}"
          top.deploy.default
        end

        desc "[internal] Rewrite reflog so HEAD@{1} will continue to point to at the next previous release. (overridden from capistrano)"
        task :cleanup, :except => { :no_release => true } do
          run "cd #{current_path}; git reflog delete --rewrite HEAD@{1}; git reflog delete --rewrite HEAD@{1}"
        end

        desc "Rolls back database to migration level of the previously deployed release"
        task :db, :roles => :db, :only => { :primary => true } do
          if fetch(:database_rollback, false)
            run "cd #{previous_release}; rake RAILS_ENV=#{rails_env} db:migrate VERSION=`cd #{File.join(current_path, 'db', 'migrate')} && ls -1 [0-9]*_*.rb | sort | tail -1 | sed -e s/_.*$//`"
          end
        end

      end

      # fixed permissions of created directories
      # creation of directories under shared has moved to create_symlinks_to_shared
      desc "Prepares one or more servers for deployment. (overridden from capistrano)"
      task :setup, :except => { :no_release => true } do
        sudo "mkdir -p #{deploy_to}"
        sudo "chown #{user} #{deploy_to}"
        sudo "chgrp #{group} #{deploy_to}" if exists?(:group)
        run "chmod g+w #{deploy_to}" if fetch(:group_writable, true)
        
        dirs = [releases_path, shared_path]
        run "mkdir -p #{dirs.join(' ')}"
        run "chmod g+w #{dirs.join(' ')}" if fetch(:group_writable, true)
      end

      # extracted out some code from finalize update, moved symlinking to shared dir and normalization of asset
      # timestamps to separate tasks
      desc "[internal] Touches up the released code. (overridden from capistrano)"
      task :finalize_update, :except => { :no_release => true } do
        run "chmod -R g+w #{latest_release}" if fetch(:group_writable, true)
        create_symlinks_to_shared
        normalize_asset_timestamps
      end
      
      # rewrote symlinking, so we actually make use of shared_children
      # shared_children can contain files as well (ie config/database.yml ?)
      desc "[internal] Create symlinks to shared"
      task :create_symlinks_to_shared do
        if (latest_release.nil? || latest_release.empty? || latest_release == "/") && !latest_release.split(/\//).any? { |path_component| path_component == "releases" }
          abort "HALT! latest_release should have a valid value! Not removing everything on your HD!"
        end
        cmd = ["rm -rf #{shared_children.map { |child| File.join(latest_release, child) }.join(' ')}"]
        shared_children.map { |child| child =~ /\// ? File.dirname(child) : nil }.compact.each do |child_parent_dir|
          # mkdir -p is making sure that the directories are there for some SCM's that don't
          # save empty folders
          cmd += "mkdir -p #{latest_release}/#{child_parent_dir}"
        end
        shared_children.each do |child|
          cmd += "ln -s #{shared_path}/#{child} #{latest_release}/#{child}"
        end
        run cmd.join(" &&\n")
      end
      
      # rewritten so assets are not necessarily under /public/, so we can support other frameworks as well
      # default remains /public/ however
      desc "[internal] normalize asset timestamps"
      task :normalize_asset_timestamps do
        if fetch(:normalize_asset_timestamps, true)
          stamp = Time.now.utc.strftime("%Y%m%d%H%M.%S")
          sub_path = fetch(:normalization_subpath, 'public')
          full_path = File.join(latest_release, sub_path)
          asset_paths = fetch(:public_children, %w(images stylesheets javascripts)).map { |p| "#{full_path}/#{p}" }.join(" ")
          run "find #{asset_paths} -exec touch -t #{stamp} {} ';'; true", :env => { "TZ" => "UTC" }
        end
      end
      
    end
  end
end