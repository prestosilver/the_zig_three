console_log: (ptr, len) => {
    const memory = new Uint8Array(instance.exports.memory.buffer);
    const msg = new TextDecoder().decode(memory.subarray(ptr, ptr + len));
    console.log(msg);
},
get_element: (ptr, len) => {
    const memory = new Uint8Array(instance.exports.memory.buffer);
    const msg = new TextDecoder().decode(memory.subarray(ptr, ptr + len));
},
