return {

    -- basic settings:
    name = 'Planetary Flights', -- name of the game for your executable
    developer = 'Don Reagan', -- dev name used in metadata of the file
    output = "../Planetary Flights", -- output location for your game, defaults to $SAVE_DIRECTORY
    version = '1.0', -- 'version' of your game, used to name the folder in output
    love = '12.0', -- version of LÖVE to use, must match github releases
    ignore = {'dist', 'ignoreme.txt', 'build.lua', '.git', '.vscode', 'Assets/Models/DualEngine.glb'}, -- folders/files to ignore in your project
    icon = 'Assets/Icons/WindowIcon.png', -- 256x256px PNG icon for game, will be converted for you

    -- optional settings:
    libs = { -- files to place in output directly rather than fuse
      all = {'License.md'}
    },
    hooks = { -- hooks to run commands via os.execute before or after building
      before_build = 'resources/preprocess.sh',
      after_build = 'resources/postprocess.sh'
    }

  }