namespace :aws do
  namespace :cloudwatch do
    namespace :alarm do
      task :disable do
        run_locally do
          cw = ServerManager.instance.cloudwatch_client

          alarm_names = cw.describe_alarms.metric_alarms.map do |alarm|
            info 'disable:' + alarm.alarm_name + ',' + alarm.actions_enabled.to_s
            alarm.alarm_name
          end
          cw.disable_alarm_actions({
            alarm_names: alarm_names
          })
        end
      end
      task :enable do
        run_locally do
          cw = ServerManager.instance.cloudwatch_client
          alarm_names = cw.describe_alarms.metric_alarms.map do |alarm|
            info 'enable:' + alarm.alarm_name + ',' + alarm.actions_enabled.to_s
            alarm.alarm_name
          end
          cw.enable_alarm_actions({
            alarm_names: alarm_names
          })
        end
      end
      desc 'describe cloudwatch alarms'
      task :list do
        run_locally do
          cw = ServerManager.instance.cloudwatch_client
          cw.describe_alarms.metric_alarms.each do |alarm|
            info alarm.alarm_name + ',' + alarm.actions_enabled.to_s
          end
        end
      end
    end
  end

  namespace :ec2 do
    namespace :auto_start_stop do
      desc 'describe instances(stop step1)'
      task :desc_stop_step1_instances do
        run_locally do
          instances = ServerManager.instance.desc_stop_instances(fetch(:auto_start_stop_step1_targets))
          instances.each do |i|
            info i.instance_id + ' ' + i.tags.to_s
          end
        end
      end
      desc 'describe instances(stop step3)'
      task :desc_stop_step3_instances do
        run_locally do
          instances = ServerManager.instance.desc_stop_instances(fetch(:auto_start_stop_step3_targets))
          instances.each do |i|
            info i.instance_id + ' ' + i.tags.to_s
          end
        end
      end
      desc 'describe instances(start step1)'
      task :desc_start_step1_instances do
        run_locally do
          instances = ServerManager.instance.desc_start_instances(fetch(:auto_start_stop_step1_targets))
          instances.each do |i|
            info i.instance_id + ' ' + i.tags.to_s
          end
        end
      end
      desc 'describe instances(start step3)'
      task :desc_start_step3_instances do
        run_locally do
          instances = ServerManager.instance.desc_start_instances(fetch(:auto_start_stop_step3_targets))
          instances.each do |i|
            info i.instance_id + ' ' + i.tags.to_s
          end
        end
      end
      desc 'describe crond process'
      task :desc_crond_process do
        on magento_job_host do
          info capture(:ps, :aux, '|', :grep, 'cron')
        end
      end
      task :stop_step1 do
        instances = ServerManager.instance.desc_stop_instances(fetch(:auto_start_stop_step1_targets))
	limit_retry = fetch(:limit_retry_to_stop_cron).to_i
        if instances.size > 0
          on magento_job_host do
            service(self, :crond, :stop)
            wait_times = 0
            while capture(:ps, '-C', 'crond', '|', :grep, 'crond', '|', :wc, '-l').to_i != 0 do
              log = []
              log << '*** ps aux | grep cron'
              log << capture(:ps, :aux, '|', :grep, 'cron')
              log << '*** ps -ef | grep -i consumer'
              log << capture(:ps, '-ef', '|', 'grep', '-i', 'consumer')
              info log.join("\n")
              info 'wait for stopping crond process'
              sleep fetch(:sleep_for_waiting_stop_cron)
              wait_times = wait_times + 1
              if limit_retry == wait_times
                set(:crond_wait_log, log.join("\n"))
                break
              end
            end
            execute :sudo, :chkconfig, :crontabcommentout, :off
          end
        end
        run_locally do
          info 'stopping step1 instances:' + fetch(:auto_start_stop_step1_targets).join(',')
          ServerManager.instance.stop_instances(fetch(:auto_start_stop_step1_targets))
          info 'stopped step1 instances:' + fetch(:auto_start_stop_step1_targets).join(',')
        end
      end
      task :stop_step2 do
        run_locally do
          info 'scheduling stop step2 instances:' + fetch(:auto_start_stop_step2_target)
          ServerManager.instance.autoscale_client.put_scheduled_update_group_action({
            auto_scaling_group_name: fetch(:auto_start_stop_step2_target),
            scheduled_action_name: 'StopMagentoWebInstances',
            start_time: Time.now + 5,
            min_size: 0,
            desired_capacity: 0,
          })
          info 'scheduled stop step2 instances:' + fetch(:auto_start_stop_step2_target)
        end
      end
      task :stop_step3 do
        run_locally do
          info 'stopping step3 instances:' + fetch(:auto_start_stop_step3_targets).join(',')
          ServerManager.instance.stop_instances(fetch(:auto_start_stop_step3_targets))
          info 'stopped step3 instances:' + fetch(:auto_start_stop_step3_targets).join(',')
        end
      end
      desc 'stop EC2 instances'
      task :stop do
        # require cap shared munin:alert:stop_<env>
        invoke 'aws:cloudwatch:alarm:disable'
        invoke 'aws:ec2:auto_start_stop:stop_step1'
        # invoke 'aws:ec2:auto_start_stop:stop_step2'
        invoke 'aws:ec2:auto_start_stop:stop_step3'

        if fetch(:crond_wait_log)
          fail "!!! stopped instances, but it forced stop crond because crond could not terminate !!!\n" + fetch(:crond_wait_log)
        end
      end

      task :start_step1 do
        run_locally do
          info 'staging step1 instances:' + fetch(:auto_start_stop_step1_targets).join(',')
          ServerManager.instance.start_instances(fetch(:auto_start_stop_step1_targets))
          info 'started step1 instances:' + fetch(:auto_start_stop_step1_targets).join(',')
        end
        on magento_job_host do
          execute :sudo, :chkconfig, :crontabcommentout, :on
        end
      end
      task :start_step2 do
        run_locally do
          resp = ServerManager.instance.autoscale_client.describe_auto_scaling_groups({
            auto_scaling_group_names: [fetch(:auto_start_stop_step2_target)]
          })
          info 'scheduling start step2 instances:' + fetch(:auto_start_stop_step2_target)
          ServerManager.instance.autoscale_client.put_scheduled_update_group_action({
            auto_scaling_group_name: fetch(:auto_start_stop_step2_target),
            scheduled_action_name: 'StartMagentoWebInstances',
            start_time: Time.now + 5,
            desired_capacity: resp.auto_scaling_groups[0].max_size,
          })
          info 'scheduled start step2 instances:' + fetch(:auto_start_stop_step2_target)
        end
      end
      task :start_step3 do
        run_locally do
          info 'staging step3 instances:' + fetch(:auto_start_stop_step3_targets).join(',')
          ServerManager.instance.start_instances(fetch(:auto_start_stop_step3_targets))
          info 'started step3 instances:' + fetch(:auto_start_stop_step3_targets).join(',')
        end
      end
      desc 'start EC2 instances'
      task :start do
        invoke 'aws:ec2:auto_start_stop:start_step3'
        # invoke 'aws:ec2:auto_start_stop:start_step2'
        invoke 'aws:ec2:auto_start_stop:start_step1'
        invoke 'aws:cloudwatch:alarm:enable'
        # require cap shared munin:alert:start_<env>
      end
    end
  end
end

namespace :munin do
  namespace :alert do
    desc 'start munin alert'
    task :start do
      on munin_host do
        as :root do
          if test :'[', '-e',  fetch(:munin_stop_mail_flag_path), ']'
            execute :sudo, :rm, fetch(:munin_stop_mail_flag_path)
          end
        end
        fetch(:munin_stop_healthcheck_port_files).each do |file|
          execute :sudo, :ln, '-nfs', '/usr/share/munin/plugins/custom-plugins/healthcheck_port', "/etc/munin/plugins/#{file}" 
        end
      end
      on bastion_host do
        fetch(:munin_stop_healthcheck_port_files).each do |file|
          execute :sudo, :ln, '-nfs', '/usr/share/munin/plugins/custom-plugins/healthcheck_port', "/etc/munin/plugins/#{file}" 
        end
      end
    end
    desc 'stop munin alert'
    task :stop do
      on munin_host do
        execute :sudo, :touch, fetch(:munin_stop_mail_flag_path)
        fetch(:munin_stop_healthcheck_port_files).each do |file|
          if test "[ -e /etc/munin/plugins/#{file} ]"
            execute :sudo, :rm, "/etc/munin/plugins/#{file}"
          end
        end
      end
      on bastion_host do
        fetch(:munin_stop_healthcheck_port_files).each do |file|
          if test "[ -e /etc/munin/plugins/#{file} ]"
            execute :sudo, :rm, "/etc/munin/plugins/#{file}"
          end
        end
      end
    end
  end
end
