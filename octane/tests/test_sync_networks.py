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


def test_parser(mocker, octane_app):
    networks = [{'key': 'value'}]

    m1 = mocker.patch('octane.commands.sync_networks.get_env_networks')
    m1.return_value = networks

    m2 = mocker.patch('octane.commands.sync_networks.update_env_networks')
    octane_app.run(["sync-networks", "1", "2"])
    assert not octane_app.stdout.getvalue()
    assert not octane_app.stderr.getvalue()
    m1.assert_called_once_with(1)
    m2.assert_called_once_with(2, networks)
