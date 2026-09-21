/*
 *  Copyright 2026 Collate.
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

import { Access } from '../generated/entity/policies/accessControl/resourcePermission';
import { Operation } from '../generated/entity/policies/policy';
import { PERMISSION_POLICY } from './permissionPolicy';
import { getOperationPermissions } from './PermissionsUtils';

const resourcePermission = (operation: Operation, access: Access) => ({
  resource: 'databaseService',
  permissions: [{ operation, access }],
});

// Mirrors PermissionProvider.tsx's RESOURCE_ALLOW_CONDITIONAL derivation.
const resourceAllowConditional = (operation: Operation) =>
  PERMISSION_POLICY.resourceLevelConditionalAllowOperations.has(operation);

describe('permissionPolicy — resourceLevelConditionalAllowOperations seam', () => {
  it('allow-lists exactly ViewBasic and ViewAll — the fix for OpenMetadata#31783', () => {
    // Locks the live default. Fails loudly if someone widens the allow-list
    // to a Create/Edit/Delete/Trigger-class operation, which would turn a
    // UI navigation fix into real cross-domain write access (see
    // permissionPolicy.ts for why those endpoints treat this check as
    // enforcement, not just gating).
    expect(
      Array.from(
        PERMISSION_POLICY.resourceLevelConditionalAllowOperations
      ).sort()
    ).toEqual([Operation.ViewAll, Operation.ViewBasic].sort());
  });

  describe.each([Operation.ViewBasic, Operation.ViewAll])(
    'operation = %s (allow-listed)',
    (operation) => {
      it('translates a resource-level conditionalAllow to permitted', () => {
        const permissions = getOperationPermissions(
          resourcePermission(operation, Access.ConditionalAllow),
          resourceAllowConditional
        );

        expect(permissions[operation]).toBe(true);
      });

      it('leaves an explicit Allow unaffected', () => {
        const permissions = getOperationPermissions(
          resourcePermission(operation, Access.Allow),
          resourceAllowConditional
        );

        expect(permissions[operation]).toBe(true);
      });

      it('leaves an explicit Deny unaffected', () => {
        const permissions = getOperationPermissions(
          resourcePermission(operation, Access.Deny),
          resourceAllowConditional
        );

        expect(permissions[operation]).toBe(false);
      });
    }
  );

  describe.each([
    Operation.Create,
    Operation.EditAll,
    Operation.Delete,
    Operation.Trigger,
  ])('operation = %s (stays strict)', (operation) => {
    it('a resource-level conditionalAllow stays denied', () => {
      const permissions = getOperationPermissions(
        resourcePermission(operation, Access.ConditionalAllow),
        resourceAllowConditional
      );

      expect(permissions[operation]).toBe(false);
    });
  });

  it('entity-level gating (no allowConditional passed) stays strict regardless of operation', () => {
    const permissions = getOperationPermissions(
      resourcePermission(Operation.ViewBasic, Access.ConditionalAllow)
    );

    expect(permissions[Operation.ViewBasic]).toBe(false);
  });
});
