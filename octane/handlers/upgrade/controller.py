# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import os

import yaml

from octane.handlers import upgrade
from octane.helpers import tasks as tasks_helpers
from octane.helpers import transformations
from octane import magic_consts
from octane.util import env as env_util
from octane.util import ssh


class ControllerUpgrade(upgrade.UpgradeHandler):
    def __init__(self, node, env, isolated):
        super(ControllerUpgrade, self).__init__(node, env, isolated)
        self.service_tenant_id = None
        self.gateway = None

    def preupgrade(self):
        self.service_tenant_id = env_util.get_service_tenant_id(
            self.env, self.node)

    def predeploy(self):
        deployment_info = self.env.get_default_facts(
            'deployment', nodes=[self.node.data['id']])
        if self.isolated:
            # From backup_deployment_info
            backup_path = os.path.join(
                magic_consts.FUEL_CACHE,
                "deployment_{0}.orig".format(self.node.data['cluster']),
            )
            if not os.path.exists(backup_path):
                os.makedirs(backup_path)
            # Roughly taken from Environment.write_facts_to_dir
            for info in deployment_info:
                fname = os.path.join(
                    backup_path,
                    "{0}_{1}.yaml".format(info['role'], info['uid']),
                )
                with open(fname, 'w') as f:
                    yaml.dump(info, f, default_flow_style=False)
        for info in deployment_info:
            if self.isolated:
                transformations.remove_physical_ports(info)
                endpoints = deployment_info[0]["network_scheme"]["endpoints"]
                self.gateway = endpoints["br-ex"]["gateway"]
            # From run_ping_checker
            info['run_ping_checker'] = False
            transformations.remove_predefined_nets(info)
            transformations.reset_gw_admin(info)
        self.env.upload_facts('deployment', deployment_info)

        tasks = self.env.get_deployment_tasks()
        tasks_helpers.skip_tasks(tasks)
        self.env.update_deployment_tasks(tasks)

    def postdeploy(self):
        # From neutron_update_admin_tenant_id
        sftp = ssh.sftp(self.node)
        with ssh.update_file(sftp, '/etc/neutron/neutron.conf') as (old, new):
            for line in old:
                if line.startswith('nova_admin_tenant_id'):
                    new.write('nova_admin_tenant_id = {0}\n'.format(
                        self.service_tenant_id))
                else:
                    new.write(line)
        ssh.call(['restart', 'neutron-server'], node=self.node)
        if self.isolated:
            # From restore_default_gateway
            ssh.call(['ip', 'route', 'delete', 'default'], node=self.node)
            ssh.call(['ip', 'route', 'add', 'default', 'via', self.gateway],
                     node=self.node)