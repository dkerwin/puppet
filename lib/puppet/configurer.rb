# The client for interacting with the puppetmaster config server.
require 'sync'
require 'timeout'
require 'puppet/network/http_pool'
require 'puppet/util'

class Puppet::Configurer
    class CommandHookError < RuntimeError; end

    require 'puppet/configurer/fact_handler'
    require 'puppet/configurer/plugin_handler'

    include Puppet::Configurer::FactHandler
    include Puppet::Configurer::PluginHandler

    # For benchmarking
    include Puppet::Util

    attr_reader :compile_time

    # Provide more helpful strings to the logging that the Agent does
    def self.to_s
        "Puppet configuration client"
    end

    class << self
        # Puppetd should only have one instance running, and we need a way
        # to retrieve it.
        attr_accessor :instance
        include Puppet::Util
    end

    # How to lock instances of this class.
    def self.lockfile_path
        Puppet[:puppetdlockfile]
    end

    def clear
        @catalog.clear(true) if @catalog
        @catalog = nil
    end

    def execute_postrun_command
        execute_from_setting(:postrun_command)
    end

    def execute_prerun_command
        execute_from_setting(:prerun_command)
    end

    # Initialize and load storage
    def dostorage
        begin
            Puppet::Util::Storage.load
            @compile_time ||= Puppet::Util::Storage.cache(:configuration)[:compile_time]
        rescue => detail
            if Puppet[:trace]
                puts detail.backtrace
            end
            Puppet.err "Corrupt state file %s: %s" % [Puppet[:statefile], detail]
            begin
                ::File.unlink(Puppet[:statefile])
                retry
            rescue => detail
                raise Puppet::Error.new("Cannot remove %s: %s" %
                    [Puppet[:statefile], detail])
            end
        end
    end

    # Just so we can specify that we are "the" instance.
    def initialize
        Puppet.settings.use(:main, :ssl, :puppetd)

        self.class.instance = self
        @running = false
        @splayed = false
    end

    def initialize_report
        Puppet::Transaction::Report.new
    end

    # Prepare for catalog retrieval.  Downloads everything necessary, etc.
    def prepare
        dostorage()

        download_plugins()

        download_fact_plugins()

        execute_prerun_command
    end

    # Get the remote catalog, yo.  Returns nil if no catalog can be found.
    def retrieve_catalog
        name = Puppet[:certname]
        catalog_class = Puppet::Resource::Catalog

        # This is a bit complicated.  We need the serialized and escaped facts,
        # and we need to know which format they're encoded in.  Thus, we
        # get a hash with both of these pieces of information.
        fact_options = facts_for_uploading()

        # First try it with no cache, then with the cache.
        result = nil
        begin
            duration = thinmark do
                result = catalog_class.find(name, fact_options.merge(:ignore_cache => true))
            end
        rescue SystemExit,NoMemoryError
            raise
        rescue Exception => detail
            puts detail.backtrace if Puppet[:trace]
            Puppet.err "Could not retrieve catalog from remote server: %s" % detail
        end

        unless result
            if ! Puppet[:usecacheonfailure]
                Puppet.warning "Not using cache on failed catalog"
                return nil
            end

            begin
                duration = thinmark do
                    result = catalog_class.find(name, fact_options.merge(:ignore_terminus => true))
                end
                Puppet.notice "Using cached catalog"
            rescue => detail
                puts detail.backtrace if Puppet[:trace]
                Puppet.err "Could not retrieve catalog from cache: %s" % detail
            end
        end

        return nil unless result

        convert_catalog(result, duration)
    end

    # Convert a plain resource catalog into our full host catalog.
    def convert_catalog(result, duration)
        catalog = result.to_ral
        catalog.finalize
        catalog.retrieval_duration = duration
        catalog.host_config = true
        catalog.write_class_file
        return catalog
    end

    # The code that actually runs the catalog.
    # This just passes any options on to the catalog,
    # which accepts :tags and :ignoreschedules.
    def run(options = {})
        begin
            prepare()
        rescue SystemExit,NoMemoryError
            raise
        rescue Exception => detail
            puts detail.backtrace if Puppet[:trace]
            Puppet.err "Failed to prepare catalog: %s" % detail
        end

        report = initialize_report()
        Puppet::Util::Log.newdestination(report)

        if catalog = options[:catalog]
            options.delete(:catalog)
        elsif ! catalog = retrieve_catalog
            Puppet.err "Could not retrieve catalog; skipping run"
            return
        end

        transaction = nil

        begin
            benchmark(:notice, "Finished catalog run") do
                transaction = catalog.apply(options)
            end
            report
        rescue => detail
            puts detail.backtrace if Puppet[:trace]
            Puppet.err "Failed to apply catalog: %s" % detail
            return
        end
    ensure
        # Now close all of our existing http connections, since there's no
        # reason to leave them lying open.
        Puppet::Network::HttpPool.clear_http_instances
        execute_postrun_command

        Puppet::Util::Log.close(report)

        send_report(report, transaction)
    end

    def send_report(report, trans = nil)
        trans.add_metrics_to_report(report) if trans
        puts report.summary if Puppet[:summarize]
        report.save() if Puppet[:report]
    rescue => detail
        puts detail.backtrace if Puppet[:trace]
        Puppet.err "Could not send report: #{detail}"
    end

    private

    def self.timeout
        timeout = Puppet[:configtimeout]
        case timeout
        when String
            if timeout =~ /^\d+$/
                timeout = Integer(timeout)
            else
                raise ArgumentError, "Configuration timeout must be an integer"
            end
        when Integer # nothing
        else
            raise ArgumentError, "Configuration timeout must be an integer"
        end

        return timeout
    end

    def execute_from_setting(setting)
        return if (command = Puppet[setting]) == ""

        begin
            Puppet::Util.execute([command])
        rescue => detail
            raise CommandHookError, "Could not run command from #{setting}: #{detail}"
        end
    end
end
