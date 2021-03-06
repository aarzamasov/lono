class Lono::Cfn::Preview < Lono::Cfn::Base
  # Override run from Base superclass, the run method is different enough with Preview
  def run
    if @options[:noop]
      puts "NOOP CloudFormation preview for #{@stack_name} update"
    else
      params = generate_all
      success = preview_change_set(params)
      delete_change_set if success && !@options[:keep] # Clean up and delete the change set
    end
  end

  def preview_change_set(params)
    success = create_change_set(params)
    display_change_set if success
  end

  def create_change_set(params)
    unless stack_exists?(@stack_name)
      puts "WARN: Cannot create a change set for the stack because the #{@stack_name} does not exists.".colorize(:yellow)
      return false
    end
    exit_unless_updatable!(stack_status(@stack_name))

    params = {
      change_set_name: change_set_name,
      stack_name: @stack_name,
      parameters: params,
      capabilities: capabilities, # ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]
    }
    set_template_body!(params)
    show_parameters(params, "cfn.create_change_set")
    begin
      cfn.create_change_set(params)
    rescue Aws::CloudFormation::Errors::ValidationError => e
      handle_error(e)
    end
    true
  end

  # Example errors:
  # "Template error: variable names in Fn::Sub syntax must contain only alphanumeric characters, underscores, periods, and colons"
  def handle_error(e)
    raise if ENV['FULL_BACKTRACE']

    if e.message =~ /^Parameters: / || e.message =~ /^Template error: /
      puts "Error creating CloudFormation preview because invalid CloudFormation parameters. Full error message:".colorize(:red)
      puts e.message
      puts "For full backtrace run command again with FULL_BACKTRACE=1"
      quit(1)
    else
      raise
    end
  end

  def display_change_set
    print "Generating CloudFormation Change Set for preview.."
    change_set = describe_change_set
    until change_set_finished?(change_set) do
      change_set = describe_change_set
      sleep 1
      print '.'
    end
    puts

    case change_set.status
    when "CREATE_COMPLETE"
      puts "CloudFormation preview for '#{@stack_name}' stack update. Changes:"
      changes = change_set.changes.sort_by do |change|
        change["resource_change"]["action"]
      end
      changes.each do |change|
        display_change(change)
      end
    when "FAILED"
      puts "Fail to create a CloudFormation preview for '#{@stack_name}' stack update. Reason:".colorize(:red)
      puts change_set.status_reason
      quit(1)
    else
      raise "hell: never come here"
    end
  end

  def delete_change_set
    cfn.delete_change_set(
      change_set_name: change_set_name,
      stack_name: @stack_name
    )
  end

  def execute_change_set
    cfn.execute_change_set(
      change_set_name: change_set_name,
      stack_name: @stack_name
    )
  end

  # generates a change set name
  def change_set_name
    @change_set_name ||= "changeset-#{Time.now.strftime("%Y%d%m%H%M%S")}"
  end

private
  # Private: formats a Aws::CloudFormation::Types::Change in pretty human readable form
  #
  # change  - Aws::CloudFormation::Types::Change
  #
  # Examples
  #
  #   display_change(change)
  #   => Remove AWS::Route53::RecordSet: DnsRecord testsubdomain.sub.tongueroo.com
  #
  # Returns nil
  #
  # change.to_h
  # {:type=>"Resource",
  #  :resource_change=>
  #   {:action=>"Remove",
  #    :logical_resource_id=>"DnsRecord",
  #    :physical_resource_id=>"testsubdomain.sub.tongueroo.com",
  #    :resource_type=>"AWS::Route53::RecordSet",
  #    :scope=>[],
  #    :details=>[]}}
  def display_change(change)
    message = if change.type == "Resource"
      c = change.resource_change
      "#{c.action} #{c.resource_type}: #{c.logical_resource_id} #{c.physical_resource_id}"
    else
      change.to_h
    end

    colors = { Remove: :red, Add: :green, Modify: :yellow }
    action = change.resource_change.action.to_sym
    message = message.colorize(colors[action]) if colors.has_key?(action)
    puts message
  end

  def change_set_finished?(change_set)
    change_set.status =~ /_COMPLETE/ || change_set.status == "FAILED"
  end

  def describe_change_set
    cfn.describe_change_set(
      change_set_name: change_set_name,
      stack_name: @stack_name
    )
  end
end
