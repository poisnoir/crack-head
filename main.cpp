#include <cstdio>
#include <GLFW/glfw3.h>
#include <mujoco/mujoco.h>

// MuJoCo structures
mjModel* m = nullptr;
mjData* d = nullptr;
mjvCamera cam;
mjvOption opt;
mjvScene scn;
mjrContext con;

// Mouse state for interaction
bool button_left = false;
double lastx = 0;
double lasty = 0;

// Handle mouse navigation (standard MuJoCo controls)
void mouse_move(GLFWwindow* window, double xpos, double ypos) {
    if (!button_left) return;
    double dx = xpos - lastx;
    double dy = ypos - lasty;
    lastx = xpos; lasty = ypos;

    int width, height;
    glfwGetWindowSize(window, &width, &height);
    mjv_moveCamera(m, mjMOUSE_ROTATE_H, dx/height, dy/height, &scn, &cam);
}

int main() {
    // 1. Load Model
    char error[1000];
    m = mj_loadXML("hello.xml", nullptr, error, 1000);
    if (!m) return 1;
    d = mj_makeData(m);

    // 2. Initialize GLFW and Window
    if (!glfwInit()) return 1;
    GLFWwindow* window = glfwCreateWindow(1200, 900, "Crack-Head Sim", NULL, NULL);
    glfwMakeContextCurrent(window);
    glfwSetCursorPosCallback(window, mouse_move);
    glfwSetMouseButtonCallback(window, [](GLFWwindow* w, int b, int a, int m) {
        if (b == GLFW_MOUSE_BUTTON_LEFT) button_left = (a == GLFW_PRESS);
        glfwGetCursorPos(w, &lastx, &lasty);
    });

    // 3. Initialize MuJoCo Visualization
    mjv_defaultCamera(&cam);
    mjv_defaultOption(&opt);
    mjv_defaultScene(&scn);
    mjr_defaultContext(&con);

    mjv_makeScene(m, &scn, 2000);      // Max 2000 objects
    mjr_makeContext(m, &con, mjFONTSCALE_150);

    // 4. Main Loop
    while (!glfwWindowShouldClose(window)) {
        // Advance simulation
        mjtNum simstart = d->time;
        while (d->time - simstart < 1.0/60.0) {
            mj_step(m, d);
        }

        // Update abstract scene and render
        mjrRect viewport = {0, 0, 0, 0};
        glfwGetFramebufferSize(window, &viewport.width, &viewport.height);

        mjv_updateScene(m, d, &opt, NULL, &cam, mjCAT_ALL, &scn);
        mjr_render(viewport, &scn, &con);

        glfwSwapBuffers(window);
        glfwPollEvents();
    }

    // Cleanup
    mj_deleteData(d);
    mj_deleteModel(m);
    mjr_freeContext(&con);
    mjv_freeScene(&scn);
    glfwTerminate();
    return 0;
}