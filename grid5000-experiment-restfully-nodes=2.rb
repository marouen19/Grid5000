require 'rubygems'
require 'restfully'       # gem install restfully
require 'net/ssh/gateway' # gem install net-ssh-gateway
require 'json'
require 'yaml'

config       = YAML.load_file(File.expand_path("~/.restclient"))['grid5000']
public_key   = Dir[File.expand_path("~/.ssh/*.pub")][0] 
fail "No public key available in ~/.ssh !" unless public_key
private_key  = File.expand_path("~/.ssh/#{File.basename(public_key, ".pub")}")
fail "No private key corresponding to the public key available in ~/.ssh !" unless File.exist?(private_key)
logger       = Logger.new(STDERR)
logger.level = Logger::INFO
logger.info "Using the SSH public key located at: #{public_key.inspect}"
gateway      = Net::SSH::Gateway.new('access.lille.grid5000.fr', config['username'])

jobs         = []
deployments  = []

# Procedure called when exiting on error
extinction   = Proc.new{
  puts "Received extinction request, killing all jobs and deployments..."
  jobs.each{|job| job.delete}
  deployments.each{|deployment| deployment.delete}
}

# Trap signals and call the extinction procedure
%w{INT TERM}.each do |signal|
  Signal.trap( signal ) do
    extinction.call
    exit(1)
  end
end

begin
  Restfully::Session.new(:base_uri => config['url']+'/sid/grid5000', :logger => logger, :username => config['username'], :password => config['password']) do |root, session|
    root.sites.each do |site|
      free_nodes = site.status.inject(0) {|memo, node_status| memo+=((node_status['system_state'] == 'free' && node_status['hardware_state'] == 'alive') ? 1 : 0)}
      if free_nodes > 1
        jobs << site.jobs.submit(:resources => "nodes=2,walltime=00:20:00", :command => "sleep 1800", :types => ["deploy"], :name => "API Main Practical") rescue nil
      else
        session.logger.info "Skipped #{site['uid']}. Not enough free nodes."
      end
    end
    jobs.compact!
    if jobs.empty?
      logger.warn "No jobs, exiting..."
      extinction.call
      exit(0)
    end
    begin
      Timeout.timeout(60*5) do
        until jobs.all?{|job| job['state'] == 'running'} do
          session.logger.info "Some jobs are not running. Waiting 10 seconds before checking again..."
          sleep 10
          jobs.each{|job| job.reload}
        end
      end
    rescue Timeout::Error => e
      session.logger.warn "One of the jobs is still not running: #{jobs.inspect}. Will be deleted..."
    end
    jobs.each do |job|
      if job['state'] != 'running'
        job.delete
      else
        deployments << job.parent.deployments.submit(:environment => "lenny-x64-base", :nodes => job['assigned_nodes'], :key => File.read(public_key)) rescue nil
      end
    end  
    deployments.compact!
    if deployments.empty?
      logger.warn "No deployments, exiting..."
      extinction.call
      exit(0)
    end
    begin
      Timeout.timeout(60*5) do # wait at most 10 mins
        until deployments.all?{|deployment| deployment['status'] == 'terminated'} do
          logger.info "Some deployments are not terminated. Waiting 100 seconds before checking again..."
          sleep 100
          deployments.each{|deployment| deployment.reload}
        end
      end
    rescue Timeout::Error => e
      session.logger.warn "One of the deployments is still not terminated: #{deployments.inspect}. Will be deleted..."
    end
    deployments.each do |deployment|
      if deployment['status'] != 'terminated'
        deployment.delete
      else
        # connect via the gateway to the first node of the deployment:
        gateway.ssh(deployment["nodes"].first, "root", :keys => [private_key], :auth_methods => ["publickey"]) do |ssh|
          print "Connecting to the node and launching the 'hostname' command...\t"
          puts ssh.exec!("hostname")
        end
      end
    end   
  end
rescue StandardError => e
  puts "Catched unexpected exception #{e.class.name}: #{e.message} - #{e.backtrace.join("\n")}"
  extinction.call
  exit(1)
end
