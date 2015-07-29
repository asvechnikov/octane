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

import logging
import time

from octane.helpers import tasks as tasks_helpers
from octane.helpers import transformations
from octane import magic_consts
from octane.util import subprocess

from cliff import command as cmd
from fuelclient.objects import environment as environment_obj
from fuelclient.objects import node as node_obj

LOG = logging.getLogger(__name__)


class ControllerUpgrade(object):
    @staticmethod
    def predeploy(node, env, isolated):
        deployment_info = env.get_default_facts(
            'deployment', nodes=[node.data['id']])
        if isolated:
            # From backup_deployment_info
            env.write_facts_to_dir('deployment', deployment_info,
                                   directory=magic_consts.FUEL_CACHE)
        for info in deployment_info:
            if isolated:
                transformations.remove_physical_ports(info)
            # From run_ping_checker
            info['run_ping_checker'] = False
            transformations.remove_predefined_nets(info)
            transformations.reset_gw_admin(info)
        env.upload_facts('deployment', deployment_info)

        tasks = env.get_deployment_tasks()
        tasks_helpers.skip_tasks(tasks)
        env.update_deployment_tasks(tasks)

    @staticmethod
    def cleanup(node, seed_env):
        ssh.call(
            ["stop", "ceph-mon", "id=node-%s" % (node.data['id'],)],
            node=node,
        )
        ssh.call(["/etc/init.d/ceph", "start", "mon"], node=node)


# TODO: use stevedore for this
role_upgrade_handlers = {
    'controller': ControllerUpgrade,
}


def get_role_upgrade_handlers(roles):
    role_handlers = []
    for role in roles:
        try:
            role_handlers.append(role_upgrade_handlers[role])
        except KeyError:
            LOG.warn("Role '%s' is not supported, skipping")
    return role_handlers


def call_role_upgrade_handlers(handlers, method, node, env, **kwargs):
    for handler in handlers[node]:
        try:
            meth = getattr(handler, method)
        except AttributeError:
            LOG.debug("No '%s' method in handler %s", method, handler.__name__)
        else:
            meth(node, env, **kwargs)


def wait_for_node(node, status, timeout=60 * 60, check_freq=60):
    node_id = node.data['id']
    LOG.debug("Waiting for node %s to transition to status '%s'",
              node_id, status)
    started_at = time.time()  # TODO: use monotonic timer
    while True:
        data = node.get_fresh_data()
        if data['status'] == 'error':
            raise Exception("Node %s fell into error status" % (node_id,))
        if data['online'] and data['status'] == status:
            LOG.info("Node %s transitioned to status '%s'", node_id, status)
            return
        if time.time() - started_at >= timeout:
            raise Exception("Timeout waiting for node %s to transition to "
                            "status '%s'" % (node_id, status))
        time.sleep(check_freq)


def upgrade_node(env_id, node_ids, isolated=False):
    # From check_deployment_status
    env = environment_obj.Environment(env_id)
    if env.data['status'] != 'new':
        raise Exception("Environment must be in 'new' status")
    nodes = [node_obj.Node(node_id) for node_id in node_ids]

    # Sanity check
    one_orig_id = None
    for node in nodes:
        orig_id = node.data['cluster']
        if orig_id == env_id:
            raise Exception(
                "Cannot upgrade node with ID %s: it's already in cluster with "
                "ID %s", node_id, env_id,
            )
        if orig_id:
            if one_orig_id and orig_id != one_orig_id:
                raise Exception(
                    "Not upgrading nodes from different clusters: %s and %s",
                    orig_id, one_orig_id,
                )
            one_orig_id = orig_id

    role_handlers = {}
    for node in nodes:
        role_handlers[node] = get_role_upgrade_handlers(node.data['roles'])

    for node in nodes:
        call_role_upgrade_handlers(role_handlers, 'preupgrade', node, env)
    for node in nodes:
        call_role_upgrade_handlers(role_handlers, 'prepare', node, env)

    subprocess.call(
        ["fuel2", "env", "move", "node", str(node_id), str(env_id)])
    for node in nodes:  # TODO: create wait_for_nodes method here
        wait_for_node(node, "discover")

    env.install_selected_nodes('provision', nodes)
    for node in nodes:  # TODO: create wait_for_nodes method here
        wait_for_node(node, "provisioned")

    for node in nodes:
        call_role_upgrade_handlers(role_handlers, 'predeploy', node, env,
                                   isolated=isolated)

    env.install_selected_nodes('deploy', nodes)
    for node in nodes:  # TODO: create wait_for_nodes method here
        wait_for_node(node, "ready")

    call_role_upgrade_handlers(role_handlers, 'cleanup', node, env)


class UpgradeNodeCommand(cmd.Command):
    """Move nodes to environment and upgrade the node"""

    def get_parser(self, prog_name):
        parser = super(UpgradeNodeCommand, self).get_parser(prog_name)
        parser.add_argument(
            '--isolated', action='store_true',
            help="Isolate node's network from original cluster")
        parser.add_argument(
            'env_id', type=int, metavar='ENV_ID',
            help="ID of target environment")
        parser.add_argument(
            'node_ids', type=int, metavar='NODE_ID', nargs='+',
            help="IDs of nodes to be moved")
        return parser

    def take_action(self, parsed_args):
        upgrade_node(parsed_args.env_id, parsed_args.node_ids,
                     isolated=parsed_args.isolated)