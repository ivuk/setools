# Copyright 2014-2016, Tresys Technology, LLC
# Copyright 2016-2018, Chris PeBenito <pebenito@ieee.org>
#
# This file is part of SETools.
#
# SETools is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 2.1 of
# the License, or (at your option) any later version.
#
# SETools is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with SETools.  If not, see
# <http://www.gnu.org/licenses/>.
#
# pylint: disable=too-many-public-methods

import logging


class PolicyTarget(PolicyEnum):

    """Enumeration of policy targets."""

    selinux = sepol.SEPOL_TARGET_SELINUX
    xen = sepol.SEPOL_TARGET_XEN


class HandleUnknown(PolicyEnum):

    """Enumeration of handle unknown settings."""

    deny = sepol.SEPOL_DENY_UNKNOWN
    allow = sepol.SEPOL_ALLOW_UNKNOWN
    reject = sepol.SEPOL_REJECT_UNKNOWN


cdef class SELinuxPolicy:
    cdef:
        sepol.sepol_policydb *handle
        sepol.sepol_handle *sh
        sepol.cat_datum_t **cat_val_to_struct
        sepol.level_datum_t **level_val_to_struct
        readonly str path
        object log

    def __init__(self, policyfile=None):
        """
        Parameter:
        policyfile  Path to a policy to open.
        """

        self.log = logging.getLogger(__name__)

        if policyfile:
            self._load_policy(policyfile)
        else:
            try:
                self._load_running_policy()
            except NameError:
                raise RuntimeError("Loading the running policy requires libselinux Python bindings")

    def __cinit__(self):
        self.handle = NULL
        self.cat_val_to_struct = NULL
        self.level_val_to_struct = NULL

    def __dealloc__(self):
        PyMem_Free(self.cat_val_to_struct)
        PyMem_Free(self.level_val_to_struct)

        if self.handle:
            sepol.sepol_policydb_free(self.handle)

        if self.sh:
            sepol.sepol_handle_destroy(self.sh)

    def __repr__(self):
        return "<SELinuxPolicy(\"{0}\")>".format(self.path)

    def __str__(self):
        return self.path

    def __deepcopy__(self, memo):
        # shallow copy as all of the members are immutable
        cdef SELinuxPolicy newobj
        newobj = SELinuxPolicy.__new__()
        newobj.handle = self.handle
        newobj.path = self.path
        newobj.log = self.log
        memo[id(self)] = newobj
        return newobj

    def __getstate__(self):
        return (self.policy, self.path, self.log, self._pickle())

    def __setstate__(self, state):
        self.policy = state[0]
        self.path = state[1]
        self.log = state[2]
        self._unpickle(state[3])

    cdef bytes _pickle(self):
        return <bytes>(<char *>self.handle)

    cdef _unpickle(self, bytes handle):
        memcpy(&self.handle, <char *>handle, sizeof(sepol.sepol_policydb*))


    #
    # Policy loading functions
    #

    cdef _load_policy(self, str filename):
        """Load the specified policy."""
        cdef:
            sepol.sepol_policy_file_t *pfile = NULL
            FILE *infile = NULL

        self.log.info("Opening SELinux policy \"{0}\"".format(filename))

        self.sh = sepol.sepol_handle_create()
        if self.sh == NULL:
            raise MemoryError

        sepol.sepol_msg_set_callback(self.sh, sepol_logging_callback, self.handle)

        if sepol.sepol_policydb_create(&self.handle) < 0:
            raise MemoryError

        if sepol.sepol_policy_file_create(&pfile) < 0:
            raise MemoryError

        infile = fopen(filename, "rb")
        if infile == NULL:
            PyErr_SetFromErrnoWithFilename(OSError, filename)

        sepol.sepol_policy_file_set_handle(pfile, self.sh)
        sepol.sepol_policy_file_set_fp(pfile, infile)

        if sepol.sepol_policydb_read(self.handle, pfile) < 0:
            raise InvalidPolicy("Invalid policy: {}. A binary policy must be specified. "
                                "(use e.g. policy.{} or sepolicy) Source policies are not "
                                "supported.".format(filename,
                                                    sepol.sepol_policy_kern_vers_max()))

        fclose(infile)
        sepol.sepol_policy_file_free(pfile)

        #
        # (Re)create data structures
        #
        if self.handle.p.attr_type_map != NULL:
            self._rebuild_attrs_from_map()
            # if source policies are supported in the
            # future this should only run on the
            # kernel policy:
            #self._synthesize_attrs()

        self._set_permissive_flags()

        if self.mls:
            self._create_mls_val_to_struct()

        self.log.info("Successfully opened SELinux policy \"{0}\"".format(filename))
        self.path = filename

    def _potential_policies(self):
        """Generate a list of potential policies to use."""
        self.log.debug("SELinuxfs exists: {}".format(selinux.selinuxfs_exists()))
        self.log.debug("Sepol version range: {}-{}".format(sepol.sepol_policy_kern_vers_min(),
                                                           sepol.sepol_policy_kern_vers_max()))
        self.log.debug("Binary policy path: {}".format(selinux.selinux_binary_policy_path()))

        # try libselinux for current policy
        if selinux.selinuxfs_exists():
            self.log.debug("Current policy path: {}".format(selinux.selinux_current_policy_path()))
            yield selinux.selinux_current_policy_path()

        # otherwise look through the supported policy versions
        base_policy_path = selinux.selinux_binary_policy_path()
        for version in range(sepol.sepol_policy_kern_vers_max(),
                             sepol.sepol_policy_kern_vers_min() - 1, -1):
            yield "{0}.{1}".format(base_policy_path, version)

    cdef _load_running_policy(self):
        """Try to load the current running policy."""
        self.log.info("Attempting to locate current running policy.")

        for filename in self._potential_policies():
            try:
                self._load_policy(filename)
            except OSError as err:
                if err.errno != ENOENT:
                    raise
            else:
                break
        else:
            raise RuntimeError("Unable to locate an SELinux policy to load.")

    #
    # Policy properties
    #
    @property
    def handle_unknown(self):
        """The handle unknown permissions setting (allow,deny,reject)"""
        return HandleUnknown(self.handle.p.handle_unknown)

    @property
    def mls(self):
        """(T/F) The policy has MLS enabled."""
        return <bint>self.handle.p.mls

    @property
    def target_platform(self):
        """The policy platform (selinux or xen)"""
        return PolicyTarget(self.handle.p.target_platform)

    @property
    def version(self):
        """The policy database version (e.g. 29)"""
        return self.handle.p.policyvers


    #
    # Policy statistics
    #
    @property
    def allow_count(self):
        """The number of (type) allow rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.allow)

    @property
    def allowxperm_count(self):
        """The number of allowxperm rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.allowxperm)

    @property
    def auditallow_count(self):
        """The number of auditallow rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.auditallow)

    @property
    def auditallowxperm_count(self):
        """The number of auditallowxperm rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.auditallowxperm)

    @property
    def boolean_count(self):
        """The number of Booleans."""
        return len(self.bools())

    @property
    def category_count(self):
        """The number of categories."""
        return sum(1 for _ in self.categories())

    @property
    def class_count(self):
        """The number of object classes."""
        return len(self.classes())

    @property
    def common_count(self):
        """The number of common permission sets."""
        return len(self.commons())

    @property
    def conditional_count(self):
        """The number of conditionals."""
        return len(self.conditionals())

    @property
    def constraint_count(self):
        """The number of standard constraints."""
        return sum(1 for c in self.constraints()
                   if c.ruletype == ConstraintRuletype.constrain)

    @property
    def default_count(self):
        """The number of default_* rules."""
        return sum(1 for d in self.defaults())

    @property
    def devicetreecon_count(self):
        """The number of Xen devicetreecon statements."""
        return len(self.devicetreecons())

    @property
    def dontaudit_count(self):
        """The number of dontaudit rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.dontaudit)

    @property
    def dontauditxperm_count(self):
        """The number of dontauditxperm rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.dontauditxperm)

    @property
    def fs_use_count(self):
        """The number of fs_use_* statements."""
        return len(self.fs_uses())

    @property
    def genfscon_count(self):
        """The number of genfscon statements."""
        return len(self.genfscons())

    @property
    def initialsids_count(self):
        """The number of initial sid statements."""
        return len(self.initialsids())

    @property
    def iomemcon_count(self):
        """The number of Xen iomemcon statements."""
        return len(self.iomemcons())

    @property
    def ioportcon_count(self):
        """The number of Xen ioportcon statements."""
        return len(self.ioportcons())

    @property
    def level_count(self):
        """The number of levels."""
        return sum(1 for _ in self.levels())

    @property
    def mlsconstraint_count(self):
        """The number of MLS constraints."""
        return sum(1 for c in self.constraints()
                   if c.ruletype == ConstraintRuletype.mlsconstrain)

    @property
    def mlsvalidatetrans_count(self):
        """The number of MLS validatetrans."""
        return sum(1 for v in self.constraints()
                   if v.ruletype == ConstraintRuletype.mlsvalidatetrans)

    @property
    def netifcon_count(self):
        """The number of netifcon statements."""
        return len(self.netifcons())

    @property
    def neverallow_count(self):
        """The number of neverallow rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.neverallow)

    @property
    def neverallowxperm_count(self):
        """The number of neverallowxperm rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.neverallowxperm)

    @property
    def nodecon_count(self):
        """The number of nodecon statements."""
        return sum(1 for n in self.nodecons())

    @property
    def pcidevicecon_count(self):
        """The number of Xen pcidevicecon statements."""
        return len(self.pcidevicecons())

    @property
    def permission_count(self):
        """The number of permissions."""
        return sum(len(c.perms) for c in chain(self.commons(), self.classes()))

    @property
    def permissives_count(self):
        """The number of permissive types."""
        return sum(1 for t in self.types() if t.ispermissive)

    @property
    def pirqcon_count(self):
        """The number of Xen pirqcon statements."""
        return len(self.pirqcons())

    @property
    def polcap_count(self):
        """The number of policy capabilities."""
        return len(self.polcaps())

    @property
    def portcon_count(self):
        """The number of portcon statements."""
        return len(self.portcons())

    @property
    def role_allow_count(self):
        """The number of role allow rules."""
        return len(RoleAllowIterator.factory(self, self.handle.p.role_allow))

    @property
    def role_transition_count(self):
        """The number of role_transition rules."""
        return len(RoleTransitionIterator.factory(self, self.handle.p.role_tr))

    @property
    def range_transition_count(self):
        return sum(1 for r in self.mlsrules()
                   if r.ruletype == MLSRuletype.range_transition)

    @property
    def role_count(self):
        """The number of roles."""
        return len(self.roles())

    @property
    def type_attribute_count(self):
        """The number of (type) attributes."""
        return len(self.typeattributes())

    @property
    def type_change_count(self):
        """The number of type_change rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.type_change)

    @property
    def type_count(self):
        """The number of types."""
        return len(self.types())

    @property
    def type_member_count(self):
        """The number of type_member rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.type_member)

    @property
    def type_transition_count(self):
        """The number of type_transition rules."""
        return sum(1 for r in self.terules()
                   if r.ruletype == TERuletype.type_transition)

    @property
    def typebounds_count(self):
        """The number of typebounds rules."""
        return len(TypeboundsIterator.factory(self, &self.handle.p.symtab[sepol.SYM_TYPES].table))

    @property
    def user_count(self):
        return len(self.users())

    @property
    def validatetrans_count(self):
        """The number of validatetrans."""
        return sum(1 for v in self.constraints()
                   if v.ruletype == ConstraintRuletype.validatetrans)

    #
    # Policy components lookup functions
    #
    def lookup_boolean(self, name):
        """Look up a Boolean."""
        for b in self.bools():
            if b == name:
                return b

        raise InvalidBoolean("{0} is not a valid Boolean".format(name))

    def lookup_category(self, name):
        """Look up a category."""
        for c in self.categories():
            if c == name:
                return c

        raise InvalidCategory("{0} is not a valid category".format(name))

    def lookup_class(self, name):
        """Look up an object class."""
        for cls in self.classes():
            if cls == name:
                return cls

        raise InvalidClass("{0} is not a valid class".format(name))

    def lookup_common(self, name):
        """Look up a common permission set."""
        for common in self.commons():
            if common == name:
                return common

        raise InvalidCommon("{0} is not a valid common".format(name))

    def lookup_initialsid(self, name):
        """Look up an initial sid."""
        for sid in self.initialsids():
            if sid == name:
                return sid

        raise InvalidInitialSid("{0} is not a valid initial SID".format(name))

    def lookup_level(self, level):
        """Look up a MLS level."""
        return Level.factory_from_string(self, level)

    def lookup_sensitivity(self, name):
        """Look up a MLS sensitivity by name."""
        for s in self.sensitivities():
            if s == name:
                return s

        raise InvalidSensitivity("{0} is not a valid sensitivity".format(name))

    def lookup_range(self, range_):
        """Look up a MLS range."""
        return Range.factory_from_string(self, range_)

    def lookup_role(self, name):
        """Look up a role by name."""
        for r in self.roles():
            if r == name:
                return r

        raise InvalidRole("{0} is not a valid role".format(name))

    def lookup_type(self, name):
        """Look up a type by name."""
        for t in self.types():
            if t == name:
                return t

        raise InvalidType("{0} is not a valid type".format(name))

    def lookup_type_or_attr(self, name):
        """Look up a type or type attribute by name."""
        for t in chain(self.types(), self.typeattributes()):
            if t == name:
                return t

        raise InvalidType("{0} is not a valid type attribute".format(name))

    def lookup_typeattr(self, name):
        """Look up a type attribute by name."""
        for t in self.typeattributes():
            if t == name:
                return t

        raise InvalidType("{0} is not a valid type attribute".format(name))

    def lookup_user(self, name):
        """Look up a user by name."""
        for u in self.users():
            if u == name:
                return u

        raise InvalidUser("{0} is not a valid user".format(name))

    #
    # Policy components iterators
    #
    def bools(self):
        """Iterator which yields all Booleans."""
        return BooleanHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_BOOLS].table)

    def bounds(self):
        """Iterator which yields all *bounds statements (typebounds, etc.)"""
        return TypeboundsIterator.factory(self, &self.handle.p.symtab[sepol.SYM_TYPES].table)

    def categories(self):
        """Iterator which yields all MLS categories."""
        return CategoryHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_CATS].table)

    def classes(self):
        """Iterator which yields all object classes."""
        return ObjClassHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_CLASSES].table)

    def commons(self):
        """Iterator which yields all commons."""
        return CommonHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_COMMONS].table)

    def defaults(self):
        """Iterator over all default_* statements."""
        for cls in ObjClassHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_CLASSES].table):
            yield from cls.defaults()

    def levels(self):
        """Iterator which yields all level declarations."""
        return LevelDeclHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_LEVELS].table)

    def polcaps(self):
        """Iterator which yields all policy capabilities."""
        return PolicyCapabilityIterator.factory(self, &self.handle.p.policycaps)

    def roles(self):
        """Iterator which yields all roles."""
        return RoleHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_ROLES].table)

    def sensitivities(self):
        """Iterator over all sensitivities."""
        return SensitivityHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_LEVELS].table)

    def types(self):
        """Iterator over all types."""
        return TypeHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_TYPES].table)

    def typeattributes(self):
        """Iterator over all (type) attributes."""
        return TypeAttributeHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_TYPES].table)

    def users(self):
        """Iterator which yields all roles."""
        return UserHashtabIterator.factory(self, &self.handle.p.symtab[sepol.SYM_USERS].table)

    #
    # Policy rules iterators
    #
    def conditionals(self):
        """Iterator over all conditional rule blocks."""
        return ConditionalIterator.factory(self, self.handle.p.cond_list)

    def mlsrules(self):
        """Iterator over all MLS rules."""
        return MLSRuleIterator.factory(self, &self.handle.p.range_tr)

    def rbacrules(self):
        """Iterator over all RBAC rules."""
        return chain(RoleAllowIterator.factory(self, self.handle.p.role_allow),
                     RoleTransitionIterator.factory(self, self.handle.p.role_tr))

    def terules(self):
        """Iterator over all type enforcement rules."""
        yield from TERuleIterator.factory(self, &self.handle.p.te_avtab)
        yield from FileNameTERuleIterator.factory(self, &self.handle.p.filename_trans)

        for c in self.conditionals():
            yield from c.true_rules()
            yield from c.false_rules()

    #
    # Constraints iterators
    #
    def constraints(self):
        """Iterator over all constraints (regular and MLS)."""
        for c in self.classes():
            yield from c.constraints()
            yield from c.validatetrans()

    #
    # In-policy Labeling statement iterators
    #
    def fs_uses(self):
        """Iterator over all fs_use_* statements."""
        return FSUseIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_FSUSE])

    def genfscons(self):
        """Iterator over all genfscon statements."""
        return GenfsconIterator.factory(self, self.handle.p.genfs)

    def initialsids(self):
        """Iterator over all initial SID statements."""
        return InitialSIDIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_ISID])

    def netifcons(self):
        """Iterator over all netifcon statements."""
        return NetifconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_NETIF])

    def nodecons(self):
        """Iterator over all nodecon statements."""
        return chain(NodeconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_NODE],
                                             NodeconIPVersion.ipv4),
                     NodeconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_NODE6],
                                             NodeconIPVersion.ipv6))

    def portcons(self):
        """Iterator over all portcon statements."""
        return PortconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_PORT])

    #
    # Xen labeling iterators
    #
    def devicetreecons(self):
        """Iterator over all devicetreecon statements."""
        return DevicetreeconIterator.factory(self,
                                             self.handle.p.ocontexts[sepol.OCON_XEN_DEVICETREE])

    def iomemcons(self):
        """Iterator over all iomemcon statements."""
        return IomemconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_XEN_IOMEM])

    def ioportcons(self):
        """Iterator over all ioportcon statements."""
        return IoportconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_XEN_IOPORT])

    def pcidevicecons(self):
        """Iterator over all pcidevicecon statements."""
        return PcideviceconIterator.factory(self,
                                            self.handle.p.ocontexts[sepol.OCON_XEN_PCIDEVICE])

    def pirqcons(self):
        """Iterator over all pirqcon statements."""
        return PirqconIterator.factory(self, self.handle.p.ocontexts[sepol.OCON_XEN_PIRQ])

    #
    # Low-level methods
    #
    cdef inline sepol.cond_bool_datum_t* boolean_value_to_datum(self, size_t value):
        """Return the class datum for the specified class value."""
        return self.handle.p.bool_val_to_struct[value]

    cdef inline str boolean_value_to_name(self, size_t value):
        """Return the name of the boolean by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_BOOLS][value])

    cdef inline sepol.cat_datum_t* category_value_to_datum(self, size_t value):
        """Return the category datum for the specified category value."""
        return self.cat_val_to_struct[value]

    cdef inline category_aliases(self, Category primary):
        """Return an interator for the aliases for the specified category."""
        return CategoryAliasHashtabIterator.factory(self,
                                                    &self.handle.p.symtab[sepol.SYM_CATS].table,
                                                    primary)

    cdef inline str category_value_to_name(self, size_t value):
        """Return the name of the category by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_CATS][value])

    cdef inline sepol.class_datum_t* class_value_to_datum(self, size_t value):
        """Return the class datum for the specified class value."""
        return self.handle.p.class_val_to_struct[value]

    cdef inline str class_value_to_name(self, size_t value):
        """Return the name of the class by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_CLASSES][value])

    cdef inline str common_value_to_name(self, size_t value):
        """Return the name of the common by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_COMMONS][value])

    cdef inline sepol.level_datum_t* level_value_to_datum(self, size_t value):
        """Return the level datum for the specified level value."""
        return self.level_val_to_struct[value]

    cdef inline str level_value_to_name(self, size_t value):
        """Return the name of the level by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_LEVELS][value])

    cdef inline sepol.role_datum_t* role_value_to_datum(self, size_t value):
        """Return the role datum for the specified role value."""
        return self.handle.p.role_val_to_struct[value]

    cdef inline str role_value_to_name(self, size_t value):
        """Return the name of the role by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_ROLES][value])

    cdef inline sensitivity_aliases(self, Sensitivity primary):
        """Return an interator for the aliases for the specified sensitivity."""
        return SensitivityAliasHashtabIterator.factory(self,
            &self.handle.p.symtab[sepol.SYM_LEVELS].table, primary)

    cdef inline type_aliases(self, Type primary):
        """Return an iterator for the aliases for the specified type."""
        return TypeAliasHashtabIterator.factory(self,
                                                &self.handle.p.symtab[sepol.SYM_TYPES].table,
                                                primary)

    cdef inline sepol.type_datum_t* type_value_to_datum(self, size_t value):
        """Return the type datum for the specified type value."""
        return self.handle.p.type_val_to_struct[value]

    cdef inline str type_value_to_name(self, size_t value):
        """Return the name of the type/attribute by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_TYPES][value])

    cdef inline sepol.user_datum_t* user_value_to_datum(self, size_t value):
        """Return the user datum for the specified user value."""
        return self.handle.p.user_val_to_struct[value]

    cdef inline str user_value_to_name(self, size_t value):
        """Return the name of the user by its value."""
        return intern(self.handle.p.sym_val_to_name[sepol.SYM_USERS][value])

    #
    # Internal methods
    #
    cdef _set_permissive_flags(self):
        """
        Set permissive flag in type datums.

        This modifies the policydb.
        """
        cdef:
            size_t bit
            sepol.ebitmap_node_t *node = NULL

        self.log.debug("Setting permissive flags in type datums.")

        bit = sepol.ebitmap_start(&self.handle.p.permissive_map, &node)
        while bit < sepol.ebitmap_length(&self.handle.p.permissive_map):
            if sepol.ebitmap_node_get_bit(node, bit):
                assert bit == self.handle.p.type_val_to_struct[bit - 1].s.value
                self.handle.p.type_val_to_struct[bit - 1].flags |= sepol.TYPE_FLAGS_PERMISSIVE

            bit = sepol.ebitmap_next(&node, bit)

    cdef _create_mls_val_to_struct(self):
        """Create *_val_to_struct arrays for categories and levels."""
        cdef:
            sepol.cat_datum_t *cat_datum
            sepol.hashtab_node_t *node
            uint32_t bucket = 0
            size_t bucket_len
            size_t map_len

        #
        # Create cat_val_to_struct  (indexed by value -1)
        #
        self.log.debug("Creating cat_val_to_struct.")

        map_len = self.handle.p.symtab[sepol.SYM_CATS].table.nel
        bucket_len = self.handle.p.symtab[sepol.SYM_CATS].table[0].size

        self.cat_val_to_struct = <sepol.cat_datum_t**>PyMem_Malloc(
            map_len * sizeof(sepol.cat_datum_t*))

        if self.cat_val_to_struct == NULL:
            raise MemoryError

        while bucket < bucket_len:
            node = self.handle.p.symtab[sepol.SYM_CATS].table[0].htable[bucket]
            while node != NULL:
                cat_datum = <sepol.cat_datum_t *>node.datum
                if cat_datum != NULL:
                    self.cat_val_to_struct[cat_datum.s.value - 1] = cat_datum

                node = node.next

            bucket += 1

        #
        # Create level_val_to_struct  (indexed by value -1)
        #
        self.log.debug("Creating level_val_to_struct.")

        map_len = self.handle.p.symtab[sepol.SYM_LEVELS].table.nel
        bucket_len = self.handle.p.symtab[sepol.SYM_LEVELS].table[0].size
        bucket = 0

        self.level_val_to_struct = <sepol.level_datum_t**>PyMem_Malloc(
            map_len * sizeof(sepol.level_datum_t*))

        if self.level_val_to_struct == NULL:
            raise MemoryError

        while bucket < bucket_len:
            node = self.handle.p.symtab[sepol.SYM_LEVELS].table[0].htable[bucket]
            while node != NULL:
                level_datum = <sepol.level_datum_t *>node.datum
                if level_datum != NULL:
                    self.level_val_to_struct[level_datum.level.sens - 1] = level_datum

                node = node.next

            bucket += 1

    cdef _rebuild_attrs_from_map(self):
        """
        Rebuilds data for the attributes and inserts them into the policydb.

        This function modifies the policydb.

        If names are missing for attributes, they are synthesized in
        the form @ttr<value> where value is the value of the attribute as
        a 0-padded four digit number.
        """

        cdef:
            size_t i, count
            int bit
            sepol.ebitmap_node_t *node = NULL
            sepol.type_datum_t *tmp_type
            char *tmp_name

        self.log.debug("Rebuilding attributes.")

        for i in range(self.handle.p.symtab[sepol.SYM_TYPES].nprim):
            tmp_type = self.handle.p.type_val_to_struct[i]

            # skip types
            if tmp_type.flavor != sepol.TYPE_ATTRIB:
                continue

            # Synthesize a name if it is missing
            if self.handle.p.sym_val_to_name[sepol.SYM_TYPES][i] == NULL:
                # synthesize name
                tmp_name = <char*>calloc(15, sizeof(char))
                if tmp_name == NULL:
                    raise MemoryError

                snprintf(tmp_name, 15, "@ttr%010zd", i + 1)

                self.handle.p.sym_val_to_name[sepol.SYM_TYPES][i] = tmp_name

                # do not free, memory is owned by policydb now.
                tmp_name = NULL

            # determine if attribute is empty
            bit = sepol.ebitmap_start(&self.handle.p.attr_type_map[i], &node)
            while bit < sepol.ebitmap_length(&self.handle.p.attr_type_map[i]):
                if sepol.ebitmap_node_get_bit(node, bit):
                    break

                bit = sepol.ebitmap_next(&node, bit)

            else:
                # skip empty attributes
                continue

            # relink the attr_type_map ebitmap to the type datum
            tmp_type.types.node = self.handle.p.attr_type_map[i].node
            tmp_type.types.highbit = self.handle.p.attr_type_map[i].highbit

            # disconnect ebitmap from attr_type_map to avoid
            # double free on policy destroy
            self.handle.p.attr_type_map[i].node = NULL
            self.handle.p.attr_type_map[i].highbit = 0

            # now go through each of the member types, and set
            # the reverse mapping
            bit = sepol.ebitmap_start(&tmp_type.types, &node)
            while bit < sepol.ebitmap_length(&tmp_type.types):
                if sepol.ebitmap_node_get_bit(node, bit):
                    orig_type = self.handle.p.type_val_to_struct[bit]
                    ebitmap_set_bit(&orig_type.types, tmp_type.s.value - 1, 1)

                bit = sepol.ebitmap_next(&node, bit)

    cdef _synthesize_attrs(self):
        """
        Builds data for empty attributes and inserts them into the policydb.

        This function modifies the policydb.

        Names created for attributes are of the form @ttr<value> where value
        is the value of the attribute as a 0-padded four digit number.

        This was pulled in from libqpol, but it doesn't seem necessary.
        """

        cdef:
            size_t i
            char *tmp_name = NULL
            char *buff = NULL
            sepol.type_datum_t *tmp_type = NULL
            sepol.ebitmap_t tmp_bmap

        self.log.debug("Synthesizing missing attributes.")

        tmp_bmap.node = NULL
        tmp_bmap.highbit = 0

        for i in range(self.handle.p.symtab[sepol.SYM_TYPES].nprim):
            if self.handle.p.type_val_to_struct[i] != NULL:
                continue

            tmp_name = <char*>calloc(15, sizeof(char))
            if tmp_name == NULL:
                raise MemoryError

            snprintf(tmp_name, 15, "@ttr%010zd", i + 1)

            tmp_type = <sepol.type_datum_t*>calloc(1, sizeof(sepol.type_datum_t))
            if tmp_type == NULL:
                free(tmp_name)
                raise MemoryError

            tmp_type.primary = 1
            tmp_type.flavor = sepol.TYPE_ATTRIB
            tmp_type.s.value = i + 1
            tmp_type.types = tmp_bmap

            try:
                hashtab_insert(self.handle.p.symtab[sepol.SYM_TYPES].table,
                               <sepol.hashtab_key_t> tmp_name,
                               <sepol.hashtab_datum_t> tmp_type)
            except Exception:
                free(tmp_name)
                free(tmp_type)
                raise

            self.handle.p.sym_val_to_name[sepol.SYM_TYPES][i] = tmp_name
            self.handle.p.type_val_to_struct[i] = tmp_type

            # memory now owned by policydb, do not free
            tmp_name = NULL
            tmp_type = NULL
