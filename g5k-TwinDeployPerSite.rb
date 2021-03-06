require 'rubygems'
require 'restfully'       # gem install restfully
require 'net/ssh/gateway' # gem install net-ssh-gateway
require 'json'
require 'pp'
require 'yaml'

config       = YAML.load_file(File.expand_path("~/.restclient"))['grid5000']
public_key   = Dir[File.expand_path("/root/.ssh/*.pub")][0] 
fail "No public key available in /root/.ssh !" unless public_key
private_key  = File.expand_path("/root/.ssh/#{File.basename(public_key, ".pub")}")
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
 if deployments.empty?
	  jobs.each{|job| job.delete}
  else
  deployments.each{|deployment| deployment.delete}
  jobs.each{|job| job.delete}
  end
}
#END extinction

# Trap signals and call the extinction procedure
%w{INT TERM}.each do |signal|
  Signal.trap( signal ) do
    extinction.call
    exit(1)
  end
end
#END trap

#main class
begin
n=0
m=0
n_message='empty';
n_message='empty';
results_n= Hash.new
results_m=Hash.new

  Restfully::Session.new(:base_uri => config['url']+'/sid/grid5000', :logger => logger, :username => config['username'], :password => config['password']) do |root, session|

#Job Creation
    root.sites.each do |site|
	    next if %w{bordeaux grenoble lille lyon nancy Orsay rennes sophia toulouse}.include?(site['uid']) # to limit the experiment's range

      free_nodes = site.status.inject(0) {|memo, node_status| memo+=((node_status['system_state'] == 'free' && node_status['hardware_state'] == 'alive') ? 1 : 0)}
      if free_nodes > 1
	#needed_nodes= (free_nodes/1.5).floor
        needed_nodes= "BEST"
	jobs << site.jobs.submit(:resources => "nodes=#{needed_nodes},walltime=00:30:00", :command => "sleep 1800", :types => ["deploy"], :name => "Grid Large Scale experiment") rescue nil
      else
        session.logger.info "Skipped #{site['uid']}. Not enough free nodes."
      end
    end
 #END Job creation
 
 #Did we end up with no jobs?
    jobs.compact!
    if jobs.empty?
      logger.warn "No jobs, exiting..."
      extinction.call
      exit(0)
    end
#END job inspection

#start time out loop
    begin
      Timeout.timeout(60*10) do
        until jobs.all?{|job| job['state'] == 'running'} do
          session.logger.info "
	  Some jobs are not running. Waiting 5 seconds before checking again...
	  "
          sleep 5
          jobs.each{|job| job.reload}
        end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the jobs is still not running: #{jobs.inspect}. Will be deleted...
      "
    end
#END time out loop

#Deploy image if job running
    jobs.each do |job|
      if job['state'] != 'running'
        job.delete
      else
	    job['assigned_nodes'].group_by{ |node_id| node_id.split("-")[0] }.each{|cluster_id, nodes|
       puts "
       Submitting deployment on #{cluster_id} nodes...
       "
       deployments<<job.parent.deployments.submit(:environment => "lenny-x64-base", :nodes => nodes, :key => File.read(public_key)) rescue nil
	
	k=nodes.length
	n=n+k
	puts "ASSIGNED NODES:
	#{nodes.pretty_inspect}
	
	#{k} new nodes are booked for the deployment on #{cluster_id}...Total #{n}...

	"}
      end
    end  
#END deployment

#Did we end up with no deployments? 
    deployments.compact!
    if deployments.empty?
      logger.warn "No deployments, exiting..."
      extinction.call
      exit(0)
      end
#END deployments inspect.

#start time out loop
    begin
      Timeout.timeout(60*15) do # wait at most 15mins
	      
        until deployments.all?{|deployment| deployment['status'] == 'terminated'} do
          logger.info "
	  Some deployments are not terminated. Waiting 10 seconds before checking again...
	  "
          sleep 10
	  
          deployments.each{|deployment| deployment.reload
	  
      if deployment['status']=='terminated'
	      deployment['result'].each_key{|key| results_n.store(key, deployment['result']["#{key}"]['state'])}
	      puts "
	      
	      #{Time.new.strftime("%H:%M:%S")} Deployment on #{deployment["nodes"].first.split("-")[0]}'s #{deployment["nodes"].length} assigned nodes is terminated!!!!
	      "
	      
         
      else 
	      puts "Waiting for the deployment on #{deployment["nodes"].first.split("-")[0]}'s #{deployment["nodes"].length} assigned nodes to be terminated..."
      # puts "OK: #{deployment.pretty_inspect}"
      end
	}
	end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the deployments is still not terminated: it Will be deleted...
      "
    end
#END time out loop.

#Delete second deployments
n_message="SECOND DEPLOYMENT: ############ #{results_n.size} nodes deployed over #{n} initail deployment#########";
    deployments.each do |deployment|
	  #  puts "#{results_n.pretty_inspect}"
	    puts "
		#{n_message}
		"
        deployment.delete
	end
#END delete second deployments
end
 rescue StandardError => e
  puts "Catched unexpected exception #{e.class.name}: #{e.message} - #{e.backtrace.join("\n")}"
  extinction.call
  exit(1)
end
