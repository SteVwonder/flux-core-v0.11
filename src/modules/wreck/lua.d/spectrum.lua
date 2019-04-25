-- Set environment specific to spectrum_mpi (derived from openmpi)
--

if wreck:getopt ("mpi") == "nospectrum" then return end

local posix = require 'posix'

function prepend_path (env_var, path)
    local env = wreck.environ
    if env[env_var] == nil then
       suffix = ''
    else
       suffix = ':'..env[env_var]
    end
    env[env_var] = path..suffix
end

function rexecd_init ()
    local env = wreck.environ
    local f = wreck.flux
    local rundir = f:getattr ('broker.rundir')

    -- Avoid shared memory segment name collisions
    -- when flux instance runs >1 broker per node.
    env['OMPI_MCA_orte_tmpdir_base'] = rundir

    env['OMPI_MCA_osc'] = "pt2pt"
    env['OMPI_MCA_pml'] = "yalla"
    env['OMPI_MCA_btl'] = "self"
    env['OMPI_MCA_coll_hcoll_enable'] = '0'
end

function rexecd_task_init ()
    -- Approximately `ulimit -Ss 10240`
    -- Used to silence IBM MCM warnings
    posix.setrlimit ("stack", 10485760)
end

-- vi: ts=4 sw=4 expandtab
