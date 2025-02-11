const express = require("express");
const app = express();
const http = require("http").createServer(app);
const io = require("socket.io")(http, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"],
  },
});

const rooms = new Map();
const MAX_ROOM_SIZE = 2;

io.on("connection", (socket) => {
  console.log("Client connected:", socket.id);

  socket.on("join", (roomId) => {
    console.log("Client joining room:", roomId);

    // Check if room exists and is full
    if (rooms.has(roomId) && rooms.get(roomId).size >= MAX_ROOM_SIZE) {
      socket.emit("room_full", { roomId });
      return;
    }

    if (!rooms.has(roomId)) {
      rooms.set(roomId, new Set());
    }
    rooms.get(roomId).add(socket.id);
    socket.join(roomId);

    const roomSize = rooms.get(roomId).size;
    io.to(roomId).emit("room_status", {
      size: roomSize,
      isRoomFull: roomSize >= MAX_ROOM_SIZE,
    });

    // If room is full after joining, notify others
    if (roomSize >= MAX_ROOM_SIZE) {
      io.emit("room_closed", { roomId });
    }
  });

  socket.on("offer", (data) => {
    socket.to(data.roomId).emit("offer", {
      sdp: data.sdp,
      type: data.type,
    });
  });

  socket.on("answer", (data) => {
    socket.to(data.roomId).emit("answer", {
      sdp: data.sdp,
      type: data.type,
    });
  });

  socket.on("ice_candidate", (data) => {
    socket.to(data.roomId).emit("ice_candidate", data.candidate);
  });

  socket.on("disconnect", () => {
    console.log("Client disconnected:", socket.id);
    rooms.forEach((clients, roomId) => {
      if (clients.has(socket.id)) {
        clients.delete(socket.id);
        if (clients.size === 0) {
          rooms.delete(roomId);
          io.emit("room_available", { roomId });
        } else {
          io.to(roomId).emit("room_status", {
            size: clients.size,
            isRoomFull: clients.size >= MAX_ROOM_SIZE,
          });
        }
      }
    });
  });
});

const PORT = process.env.PORT || 4000;
http.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
