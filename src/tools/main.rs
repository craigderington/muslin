//! Native Muslin multicall replacements for selected BusyBox applets.

use std::env;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::raw::{c_char, c_int};
use std::path::Path;

const SYSLOG_ACTION_READ_ALL: c_int = 3;
const SYSLOG_ACTION_SIZE_BUFFER: c_int = 10;

extern "C" {
    fn klogctl(action: c_int, buffer: *mut c_char, length: c_int) -> c_int;
}

fn copy_reader(mut reader: impl Read) -> io::Result<()> {
    io::copy(&mut reader, &mut io::stdout().lock())?;
    Ok(())
}

fn cat(arguments: &[String]) -> io::Result<()> {
    if arguments.is_empty() {
        return copy_reader(io::stdin().lock());
    }
    for path in arguments {
        if path == "-" {
            copy_reader(io::stdin().lock())?;
        } else {
            copy_reader(File::open(path)?)?;
        }
    }
    Ok(())
}

fn list_directory(path: &Path) -> io::Result<()> {
    let mut names = fs::read_dir(path)?
        .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
        .filter(|name| !name.as_encoded_bytes().starts_with(b"."))
        .collect::<Vec<_>>();
    names.sort();
    for name in names {
        println!("{}", name.to_string_lossy());
    }
    Ok(())
}

fn ls(arguments: &[String]) -> io::Result<()> {
    if arguments.is_empty() {
        return list_directory(Path::new("."));
    }
    for (index, argument) in arguments.iter().enumerate() {
        let path = Path::new(argument);
        if arguments.len() > 1 {
            if index > 0 {
                println!();
            }
            println!("{argument}:");
        }
        if path.is_dir() {
            list_directory(path)?;
        } else {
            println!("{argument}");
        }
    }
    Ok(())
}

fn ps() -> io::Result<()> {
    println!("PID COMMAND");
    let mut processes = Vec::new();
    for entry in fs::read_dir("/proc")? {
        let entry = entry?;
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|value| value.parse::<u32>().ok()) else {
            continue;
        };
        let stat = fs::read_to_string(entry.path().join("stat"))?;
        let command = stat
            .split_once('(')
            .and_then(|(_, rest)| rest.rsplit_once(')'))
            .map_or("?", |(command, _)| command);
        processes.push((pid, command.to_owned()));
    }
    processes.sort_by_key(|(pid, _)| *pid);
    for (pid, command) in processes {
        println!("{pid:>3} {command}");
    }
    Ok(())
}

fn dmesg() -> io::Result<()> {
    let size = unsafe { klogctl(SYSLOG_ACTION_SIZE_BUFFER, std::ptr::null_mut(), 0) };
    if size < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut buffer = vec![0_u8; size as usize];
    let bytes = unsafe {
        klogctl(
            SYSLOG_ACTION_READ_ALL,
            buffer.as_mut_ptr().cast::<c_char>(),
            size,
        )
    };
    if bytes < 0 {
        return Err(io::Error::last_os_error());
    }
    io::stdout().lock().write_all(&buffer[..bytes as usize])
}

fn main() {
    let arguments = env::args().collect::<Vec<_>>();
    let applet = Path::new(arguments.first().map_or("muslin-tools", String::as_str))
        .file_name()
        .and_then(OsStr::to_str)
        .unwrap_or("muslin-tools");
    let result = match applet {
        "cat" => cat(&arguments[1..]),
        "ls" => ls(&arguments[1..]),
        "ps" => ps(),
        "dmesg" => dmesg(),
        _ => {
            eprintln!("muslin-tools: invoke as ls, cat, ps, or dmesg");
            std::process::exit(2);
        }
    };
    if let Err(error) = result {
        let _ = writeln!(io::stderr().lock(), "{applet}: {error}");
        std::process::exit(1);
    }
}
