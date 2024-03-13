# Author:: Christopher Brown (<cb@chef.io>)
# Author:: Daniel DeLeo (<dan@chef.io>)
# Copyright:: Copyright (c) Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative "../version"
require "chef-config/path_helper" unless defined?(ChefConfig::PathHelper)
require "chef/run_list" unless defined?(Chef::RunList)
require_relative "gem_glob_loader"
require_relative "hashed_command_loader"

class Chef
  class Knife
    #
    # Public Methods of a Subcommand Loader
    #
    # load_commands            - loads all available subcommands
    # load_command(args)       - loads subcommands for the given args
    # list_commands(args)      - lists all available subcommands,
    #                            optionally filtering by category
    # subcommand_files         - returns an array of all subcommand files
    #                            that could be loaded
    # command_class_from(args) - returns the subcommand class for the
    #                            user-requested command
    #
    class SubcommandLoader
      attr_reader :chef_config_dir

      # A small factory method.  Eventually, this is the only place
      # where SubcommandLoader should know about its subclasses, but
      # to maintain backwards compatibility many of the instance
      # methods in this base class contain default implementations
      # of the functions sub classes should otherwise provide
      # or directly instantiate the appropriate subclass
      def self.for_config(chef_config_dir)
        if autogenerated_manifest?
          Chef::Log.trace("Using autogenerated hashed command manifest #{plugin_manifest_path}")
          Knife::SubcommandLoader::HashedCommandLoader.new(chef_config_dir, plugin_manifest)
        else
          Knife::SubcommandLoader::GemGlobLoader.new(chef_config_dir)
        end
      end

      # There are certain situations where we want to shortcut the loader selection
      # in self.for_config and force using the GemGlobLoader
      def self.gem_glob_loader(chef_config_dir)
        Knife::SubcommandLoader::GemGlobLoader.new(chef_config_dir)
      end

      def self.plugin_manifest?
        plugin_manifest_path && File.exist?(plugin_manifest_path)
      end

      def self.autogenerated_manifest?
        plugin_manifest? && plugin_manifest.key?(HashedCommandLoader::KEY)
      end

      def self.plugin_manifest
        Chef::JSONCompat.from_json(File.read(plugin_manifest_path))
      end

      def self.plugin_manifest_path
        ChefConfig::PathHelper.home(".chef", "plugin_manifest.json")
      end

      def self.generate_hash
        output = if plugin_manifest?
                   plugin_manifest
                 else
                   { Chef::Knife::SubcommandLoader::HashedCommandLoader::KEY => {} }
                 end
        output[Chef::Knife::SubcommandLoader::HashedCommandLoader::KEY]["plugins_paths"] = Chef::Knife.subcommand_files
        output[Chef::Knife::SubcommandLoader::HashedCommandLoader::KEY]["plugins_by_category"] = Chef::Knife.subcommands_by_category
        output
      end

      def self.write_hash(data)
        plugin_manifest_dir = File.expand_path("..", plugin_manifest_path)
        FileUtils.mkdir_p(plugin_manifest_dir) unless File.directory?(plugin_manifest_dir)
        File.open(plugin_manifest_path, "w") do |f|
          f.write(Chef::JSONCompat.to_json_pretty(data))
        end
      end

      def initialize(chef_config_dir)
        @chef_config_dir = chef_config_dir
      end

      # Load all the sub-commands
      def load_commands
        return true if @loaded

        subcommand_files.each { |subcommand| Kernel.load subcommand }
        @loaded = true
      end

      def force_load
        @loaded = false
        load_commands
      end

      def load_command(_command_args)
        load_commands
      end

      def list_commands(pref_cat = nil)
        load_commands
        if pref_cat && Chef::Knife.subcommands_by_category.key?(pref_cat)
          { pref_cat => Chef::Knife.subcommands_by_category[pref_cat] }
        else
          Chef::Knife.subcommands_by_category
        end
      end

      def command_class_from(args)
        cmd_words = positional_arguments(args)
        load_command(cmd_words)
        result = Chef::Knife.subcommands[find_longest_key(Chef::Knife.subcommands,
          cmd_words, "_")]
        result || Chef::Knife.subcommands[args.first.tr("-", "_")]
      end

      def guess_category(args)
        category_words = positional_arguments(args)
        category_words.map! { |w| w.split("-") }.flatten!
        find_longest_key(Chef::Knife.subcommands_by_category,
          category_words, " ")
      end

      #
      # This is shared between the custom_manifest_loader and the gem_glob_loader
      def find_subcommands_via_dirglob
        # The "require paths" of the core knife subcommands bundled with chef
        files = Dir[File.join(ChefConfig::PathHelper.escape_glob_dir(File.expand_path("../../knife", __dir__)), "*.rb")]
        version_file_match = /#{Regexp.escape(File.join('chef', 'knife', 'version.rb'))}/
        subcommand_files = {}
        files.each do |knife_file|
          rel_path = knife_file[/#{KNIFE_ROOT}#{Regexp.escape(File::SEPARATOR)}(.*)\.rb/, 1]
          # Exclude version.rb file for the gem. It's not a knife command, and  force-loading it later
          # because loaded via in subcommand files generates CLI warnings about its consts already having been defined
          next if knife_file&.match?(version_file_match)

          subcommand_files[rel_path] = knife_file
        end
        subcommand_files
      end

      #
      # Utility function for finding an element in a hash given an array
      # of words and a separator.  We find the longest key in the
      # hash composed of the given words joined by the separator.
      #
      def find_longest_key(hash, words, sep = "_")
        words = words.dup
        match = nil
        until match || words.empty?
          candidate = words.join(sep).tr("-", "_")
          if hash.key?(candidate)
            match = candidate
          else
            words.pop
          end
        end
        match
      end

      #
      # The positional arguments from the argument list provided by the
      # users. Used to search for subcommands and categories.
      #
      # @return [Array<String>]
      #
      def positional_arguments(args)
        args.grep(/^(([[:alnum:]])[[:alnum:]\_\-]+)$/)
      end

      # Returns an Array of paths to knife commands located in
      # chef_config_dir/plugins/knife/ and ~/.chef/plugins/knife/
      def site_subcommands
        user_specific_files = []

        if chef_config_dir
          user_specific_files.concat Dir.glob(File.expand_path("plugins/knife/*.rb", ChefConfig::PathHelper.escape_glob_dir(chef_config_dir)))
        end

        # finally search ~/.chef/plugins/knife/*.rb
        ChefConfig::PathHelper.home(".chef", "plugins", "knife") do |p|
          user_specific_files.concat Dir.glob(File.join(ChefConfig::PathHelper.escape_glob_dir(p), "*.rb"))
        end

        user_specific_files
      end
    end
  end
end
