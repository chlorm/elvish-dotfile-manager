# Copyright (c) 2016, 2018-2021, Cody Opel <cwopel@chlorm.net>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# FIXME: maybe make this a generic git updater
#   https://github.com/chlorm/kratos/blob/c82657c9565ce041ade093c473c3f6d0b25be0ad/modules/updater/main.bash


use github.com/chlorm/elvish-stl/env
use github.com/chlorm/elvish-stl/exec
use github.com/chlorm/elvish-stl/io
use github.com/chlorm/elvish-stl/map
use github.com/chlorm/elvish-stl/os
use github.com/chlorm/elvish-stl/path
use github.com/chlorm/elvish-stl/re
use github.com/chlorm/elvish-stl/str


var EXT-GENERATE = '.generate'
var EXT-INSTALL-PRE = '.install-pre'
var EXT-INSTALL = '.install'
var EXT-INSTALL-POST = '.install-post'

# TODO:
# - Should we use an ext for os-specific hooks or require implementing os logic as needed in hooks
# - allow many repos
# - clone to a single directory
# - link or install files from the lib dir
# - track all linked/installed files
# - add-repo, add-file, add-directory, update-file commands
# - Figure out windows support, possibly in a more minimal fashion.
#   - Windows cannot use symlinks as they require admistrator privledges.
#   - Need to rewrite current system to install files instead of symlinking

fn -evaluate-repls {|fptr|
    var repls = [&]

    # Parse for variables (e.g. `@{VAR}@`)
    var variables = [ (re:find '(@{.*?}@)' $fptr) ]
    for variable $variables {
        # Skip keys that already exist
        if (map:has-key $repls $variable) {
            continue
        }
        # Evaluate variable
        var result = (env:get (re:find '@{(.*?)}@' $variable))
        set repls[$variable] = $result
    }
    # Parse for command substitutions (e.g. `@(command --arg)@`)
    var commandSubstitutions = [ (re:find '(@\(.*?\)@)' $fptr) ]
    for commandSubstitution $commandSubstitutions {
        # Skip keys that already exist
        if (map:has-key $repls $commandSubstitution) {
            continue
        }
        # Evaluate command substitution
        var result = (
            e:elvish -c (re:find '@\((.*?)\)@' $commandSubstitution)
        )
        set repls[$commandSubstitution] = $result
    }

    # Replace template sting with evaluated string.
    for repl [ (map:keys $repls) ] {
        set fptr = (str:replace $repl $repls[$repl] $fptr)
    }
    put $fptr
}

# FIXME: install to lib dir and symlink from lib?
fn -install-hook {|dotfilesDir dotfile|
    var installPath = (path:join (path:home) '.'$dotfile)
    if (not (os:exists $installPath)) {
        echo 'Installing: '$dotfile >&2
    } else {
        echo 'Updating: '$dotfile >&2
    }

    # FIXME: Test symlink target before removing
    if (os:exists $installPath) {
        os:remove $installPath
    }

    if (not (os:is-dir (path:dirname $installPath))) {
        os:makedirs (path:dirname $installPath)
    }
    os:symlink (path:join $dotfilesDir $dotfile) $installPath
}

# Checks if a path contains hidden files/directories (e.g. path/.hidden-file)
fn -is-path-hidden {|path|
    var hidden = $false
    var p = $path
    while $true {
        if (str:has-prefix (path:basename $p) '.') {
            set hidden = $true
            break
        }
        set p = (path:dirname $p)
        # Root of path
        if (==s $p '.') {
            break
        }
    }
    put $hidden
}

fn install-singleton {|dotfilesDir dotfile|
  var dotfilePath = (path:join $dotfilesDir $dotfile)

    # FIXME: install generated file with install-hook/.install
    if (str:has-suffix $dotfile $EXT-GENERATE) {
        var fptr = (-evaluate-repls (io:open $dotfilePath))
        # Override vars
        set dotfile = (str:replace $EXT-GENERATE '' $dotfile)
        set dotfilePath = (path:join $dotfilesDir $dotfile)
        # FIXME: not sure we want to install this way, but works for now
        echo $fptr > $dotfilePath
    }

    # FIXME: this should not be necessary
    if (not (os:exists $dotfilePath)) {
        fail 'File does not exist: '$dotfilePath
    }

    # PRE-Install
    var dotInstallPre = $dotfilePath$EXT-INSTALL-PRE
    if (os:exists $dotInstallPre) {
        try {
            e:elvish $dotInstallPre
        } catch error {
            fail $error
        }
    }

    # Install
    var dotInstall = $dotfilePath$EXT-INSTALL
    if (os:exists $dotInstall) {
        e:elvish $dotInstall
    } else {
        -install-hook $dotfilesDir $dotfile
    }

    # POST-Install
    var dotInstallPost = $dotfilePath$EXT-INSTALL-POST
    if (os:exists $dotInstallPost) {
        try {
            e:elvish $dotInstallPost
        } catch error {
            print $error
        }
    }
}

# FIXME: support multiple dirs (repos)
fn install {|dotfilesDir|
    if (not (os:is-dir $dotfilesDir)) {
        fail 'Dotfile directory does not exist: '$dotfilesDir
    }

    # FIXME: lookup XDG_CONFIG_HOME and use path rel to HOME
    var ignoreList = [
        'config/systemd'
    ]

    var dotIgnore = (path:join $dotfilesDir '.dotignore')
    if (os:is-file $dotIgnore) {
        set ignoreList = [
            $@ignoreList
            $dotIgnore
            (io:cat $dotIgnore)
        ]
    }

    # FIXME: switch to path:walk when adding Windows support
    var dotfiles = [(
        exec:cmd-out 'find' $dotfilesDir ^
            '-type' 'f' ^
            '-not' '-iwholename' '*.git*' ^
            '-printf' '%P\n'
    )]
    for dotfile $dotfiles {
        # Ignore hidden files
        if (-is-path-hidden $dotfile) {
            continue
        }

        var ignoreSkip = $false
        for ignore $ignoreList {
            if (==s '' $ignore) {
                continue
            }
            # Respect ignoring files within ignored directories
            if (re:match '.*'$ignore'.*' $dotfile) {
                set ignoreSkip = $true
                break
            }
        }
        if $ignoreSkip {
            continue
        }

        # Exclude hooks
        # FIXME: don't exclude .install, allow install without an associated dotfile
        var dotfileHooks = [
            $EXT-INSTALL-PRE
            $EXT-INSTALL
            $EXT-INSTALL-POST
        ]
        var hookSkip = $false
        for hook $dotfileHooks {
            if (str:has-suffix $dotfile $hook) {
                set hookSkip = $true
                break
            }
        }
        if $hookSkip {
            continue
        }

        install-singleton $dotfilesDir $dotfile
    }
}

fn update {
    # TODO
}

