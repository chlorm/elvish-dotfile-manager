# Copyright (c) 2016, 2018-2020, Cody Opel <cwopel@chlorm.net>
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


use re
use str
use github.com/chlorm/elvish-stl/io
use github.com/chlorm/elvish-stl/os
use github.com/chlorm/elvish-stl/path
use github.com/chlorm/elvish-stl/regex


# TODO: Figure out windows support, possibly in a more minimal fashion.

fn -generate-hook [dotfile dotfiles-dir]{
  echo 'Generating: '$dotfile >&2
  local:file = (io:open (path:join $dotfiles-dir $dotfile))

  # Parse for variables (e.g. `@{VAR}@`)
  local:variables = [ (regex:find '(@{.*?}@)' $file) ]
  # Parse for command substitutions (e.g. `@(command --arg)@`)
  local:command-substitutions = [ (regex:find '(@\(.*?\)@)' $file) ]

  local:repls = [&]
  for variable $variables {
    # Skip keys that already exist
    if (has-key $repls $variable) {
      continue
    }
    # Evaluate variable
    local:result = (get-env (regex:find '@{(.*?)}@' $variable))
    repls[$variable]=$result
  }
  for local:command-substitution $command-substitutions {
    # Skip keys that already exist
    if (has-key $repls $variable) {
      continue
    }
    # Evaluate command substitution
    local:result = (e:elvish -c (regex:find '@\((.*?)\)@' $command-substitution))
    repls[$command-substitution]=$result
  }
  # Replace template sting with evaluated string.
  for local:repl [ (keys $repls) ] {
    file = (str:replace $repl $repls[$repl] $file)
  }

  local:out = (str:replace '.generate' '' $dotfile)

  os:makedirs (path:dirname $E:HOME'/.'$out)
  echo $file > $E:HOME'/.'$out
}

fn -install-hook [source-path dotfiles-dir]{
  local:install-path = (path:join (get-env HOME) '.'$source-path)
  if (not (os:exists $install-path)) {
    echo 'Installing: '$source-path >&2
  } else {
    echo 'Updating: '$source-path >&2
  }

  # FIXME: Test symlink target before removing
  if (os:exists $install-path) {
    os:remove $install-path
  }

  if (not (os:is-dir (path:dirname $install-path))) {
    os:makedirs (path:dirname $install-path)
  }
  os:symlink (path:join $dotfiles-dir $source-path) $install-path
}

# Checks if a path contains hidden files/directories (e.g. path/.hidden-file)
fn -is-path-hidden [path]{
  local:hidden = $false
  local:p = $path
  while $true {
    if (has-prefix (path:basename $p) '.') {
      hidden = $true
      break
    }
    p = (path:dirname $p)
    # Root of path
    if (==s '.' $p) {
      break
    }
  }
  put $hidden
}

# FIXME: support multiple dirs (repos)
fn install [dotfiles-dir]{
  if (not (os:is-dir $dotfiles-dir)) {
    fail 'Dotfile directory does not exist: '$dotfiles-dir
  }

  # FIXME: lookup XDG_CONFIG_HOME and use path rel to HOME
  local:ignore-list = [
    'config/systemd'
  ]

  local:dot-ignore = (path:join $dotfiles-dir '.dotignore')
  if (os:is-file $dot-ignore) {
    ignore-list = [
      $@ignore-list
      $dot-ignore
      (io:cat $dot-ignore)
    ]
  }

  # FIXME: switch to path:walk when adding Windows support
  local:dotfiles = [
    (e:find $dotfiles-dir -type f -not -iwholename '*.git*' -printf '%P\n')
  ]
  for local:dotfile $dotfiles {
    local:dotfile-path = (path:join $dotfiles-dir $dotfile)
    # FIXME: this should not be necessary
    if (not (os:exists $dotfile-path)) {
      echo 'File does not exist: '$dotfile-path
      continue
    }

    # Ignore hidden files
    if (-is-path-hidden $dotfile) {
      continue
    }

    local:ignore-skip = $false
    for local:ignore $ignore-list {
      if (==s '' $ignore) {
        continue
      }
      # Respect ignoring files within ignored directories
      if (re:match '.*'$ignore'.*' $dotfile) {
        ignore-skip = $true
        break
      }
    }
    if $ignore-skip {
      continue
    }

    # Exclude hooks
    local:dotfile-hooks = [
      'install-pre'
      'install-post'
      'generate-pre'
      'generate-post'
    ]
    local:hook-skip=$false
    for local:hook $dotfile-hooks {
      if (has-suffix $dotfile $hook) {
        hook-skip=$true
        break
      }
    }
    if $hook-skip {
      continue
    }

    # PRE-Install
    local:dot-install-pre = $dotfile-path'.install-pre'
    if (os:exists $dot-install-pre) {
      try {
        e:elvish $dot-install-pre
      } except error {
        print $error
      }
    }

    # Install
    if (has-suffix $dotfile '.generate') {
      if (os:exists $dotfile-path'.generate-pre') {
        e:elvish $dotfile-path'.generate-pre'
      }
      -generate-hook $dotfile $dotfiles-dir
      if (os:exists %dotfile-path'.generate-post') {
        e:elvish $dotfile-path'.generate-post'
      }
    } else {
      -install-hook $dotfile $dotfiles-dir
    }

    # POST-Install
    local:dot-install-post = $dotfile-path'.install-post'
    if (os:exists $dot-install-post) {
      try {
        e:elvish $dot-install-post
      } except error {
        print $error
      }
    }
  }
}

fn update {
  # TODO
}

